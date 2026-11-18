//! Runs concurrent Redis-like request workloads and reports throughput and batch latency.

const std = @import("std");
const consts = @import("consts.zig");

/// Client counts exercised by default when the caller does not choose one.
const client_counts = [_]usize{ 1, 2, 4, 8, 16 };
/// Wire response expected for a successful SET operation.
const set_response = "+OK\r\n\x03";

/// Selects whether the benchmark targets an in-memory or persistence workload.
const Mode = enum {
    /// Runs GET, SET, and balanced mixed workloads against memory storage.
    ram,
    /// Runs persistence-specific traffic against the configured server.
    persistence,
};
/// Selects the command mix sent by each client.
const Scenario = enum {
    /// Sends only GET requests after initializing each worker's key.
    get,
    /// Sends only SET requests.
    set,
    /// Alternates GET and SET requests, beginning with GET.
    mixed,
    /// Labels the persistence-mode workload in output.
    persistence,
};

/// Validated workload settings, including connection and payload parameters.
const Options = struct {
    /// Server address used to open worker connections.
    host: []const u8 = consts.HOST,
    /// TCP port to which each worker connects.
    port: u16 = consts.PORT,
    /// Number of requests issued by each worker; must be even.
    requests: usize = 10000,
    /// Requests grouped into one write/read batch; one records per-command latency.
    pipeline: usize = 1,
    /// Number of bytes stored and fetched in each value.
    value_size: usize = 20,
    /// Explicit number of simultaneous clients, or null to use the standard series.
    clients: ?usize = null,
    /// Workload class; required on the command line.
    mode: Mode,
};

/// Parses paired command-line options and rejects missing, unknown, or out-of-range values.
pub fn parseOptions(args: []const [:0]const u8) !Options {
    var options = Options{ .mode = undefined };
    var has_mode = false;
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return error.MissingOptionValue;
        const name = args[i];
        const arg = args[i + 1];
        if (std.mem.eql(u8, name, "--mode")) {
            options.mode = std.meta.stringToEnum(Mode, arg) orelse return error.InvalidMode;
            has_mode = true;
        } else if (std.mem.eql(u8, name, "--host")) {
            options.host = arg;
        } else if (std.mem.eql(u8, name, "--port")) {
            options.port = try std.fmt.parseInt(u16, arg, 10);
            if (options.port == 0) return error.InvalidPort;
        } else if (std.mem.eql(u8, name, "--requests")) {
            options.requests = try std.fmt.parseInt(usize, arg, 10);
            if (options.requests < 2 or options.requests % 2 != 0) return error.InvalidRequestCount;
        } else if (std.mem.eql(u8, name, "--pipeline")) {
            options.pipeline = try std.fmt.parseInt(usize, arg, 10);
            if (options.pipeline == 0 or options.pipeline > 4096) return error.InvalidPipeline;
        } else if (std.mem.eql(u8, name, "--value-size")) {
            options.value_size = try std.fmt.parseInt(usize, arg, 10);
            if (options.value_size == 0 or options.value_size > 1024 * 1024) return error.InvalidValueSize;
        } else if (std.mem.eql(u8, name, "--clients")) {
            options.clients = try std.fmt.parseInt(usize, arg, 10);
            if (options.clients.? == 0 or options.clients.? > 128) return error.InvalidClientCount;
        } else return error.UnknownOption;
    }
    if (!has_mode) return error.MissingMode;
    return options;
}

/// Reports whether request `index` is a read in the selected command mix.
pub fn isGet(scenario: Scenario, index: usize) bool {
    return scenario == .get or (scenario == .mixed and index % 2 == 0);
}

/// Computes a nearest-rank percentile from ascending latency samples.
/// The caller must provide a non-empty sorted slice and a percentile in 1...100.
pub fn percentile(sorted: []const u64, percent: usize) u64 {
    // Nearest-rank percentile, with one-based ranks.
    const rank = (sorted.len * percent + 99) / 100;
    return sorted[rank - 1];
}

/// Writes one complete request, flushes it, then verifies its matching response.
fn command(
    writer: *std.Io.net.Stream.Writer,
    reader: *std.Io.net.Stream.Reader,
    request: []const u8,
    expected: []const u8,
) !void {
    try writer.interface.writeAll(request);
    try writer.interface.flush();
    try expectResponse(reader, expected);
}

/// Reads through the frame terminator and fails when the response differs.
fn expectResponse(reader: *std.Io.net.Stream.Reader, expected: []const u8) !void {
    const response = try reader.interface.takeDelimiterInclusive(consts.EXT_CHAR);
    if (!std.mem.eql(u8, response, expected)) {
        std.debug.print("Unexpected server response (first 256 bytes): {s}\n", .{response[0..@min(response.len, 256)]});
        return error.UnexpectedResponse;
    }
}

/// Immutable workload data and synchronization shared by all client workers.
const Shared = struct {
    /// I/O interface used for socket operations and events.
    io: std.Io,
    /// Resolved server endpoint used by every worker.
    address: std.Io.net.IpAddress,
    /// Request pattern currently being measured.
    scenario: Scenario,
    /// Number of workers participating in the run.
    count: usize,
    /// Parsed configuration shared with each client.
    options: Options,
    /// Deterministic payload written by SET requests.
    value: []const u8,
    /// Expected framed response to GET requests.
    get_response: []const u8,
    /// Counts workers that reached readiness, including workers that failed early.
    ready_count: std.atomic.Value(usize) = .init(0),
    /// Opens once all workers have reached their start barrier.
    ready: std.Io.Event = .unset,
    /// Releases the workers together so elapsed time covers the workload.
    start: std.Io.Event = .unset,
};

/// Owns one client connection and its latency samples for a scenario run.
const Worker = struct {
    /// Shared endpoint, workload, and barrier state.
    shared: *Shared,
    /// Stable worker index used to create a private key.
    id: usize,
    /// Per-command or per-pipeline-batch elapsed times in nanoseconds.
    samples: []u64,
    /// Captures the worker's first execution error for the parent thread.
    result: ?anyerror = null,
    /// Awake-clock timestamp taken after the worker finishes its requests.
    finished_ns: i96 = 0,

    /// Thread entry point; stores execution errors instead of unwinding across threads.
    fn run(self: *Worker) void {
        self.execute() catch |err| {
            self.result = err;
        };
    }

    /// Connects, primes its key, waits for the coordinated start, and records requests.
    /// Socket, buffers, and pending I/O selection are released on completion or failure.
    fn execute(self: *Worker) !void {
        const shared = self.shared;
        var announced = false;
        defer if (!announced) self.announceReady();

        const socket = try shared.address.connect(shared.io, .{ .mode = .stream });
        defer socket.close(shared.io);
        const allocator = std.heap.page_allocator;
        var writer_buffer: [65536]u8 = undefined;
        const reader_buffer = try allocator.alloc(u8, @max(65536, shared.get_response.len));
        defer allocator.free(reader_buffer);
        var writer = socket.writer(shared.io, &writer_buffer);
        var reader = socket.reader(shared.io, reader_buffer);

        var key_buffer: [64]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buffer, "__zcached_benchmark_{d}__", .{self.id});
        const set_request = try std.fmt.allocPrint(allocator, "*3\r\n$3\r\nSET\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n\x03", .{ key.len, key, shared.value.len, shared.value });
        defer allocator.free(set_request);
        var get_buffer: [256]u8 = undefined;
        const get_request = try std.fmt.bufPrint(&get_buffer, "*2\r\n$3\r\nGET\r\n${d}\r\n{s}\r\n\x03", .{ key.len, key });

        try command(&writer, &reader, set_request, set_response);

        if (shared.options.pipeline == 1) {
            self.announceReady();
            announced = true;
            shared.start.waitUncancelable(shared.io);
            for (self.samples, 0..) |*sample, i| {
                const get = isGet(shared.scenario, i);
                const before = std.Io.Clock.awake.now(shared.io).nanoseconds;
                try command(&writer, &reader, if (get) get_request else set_request, if (get) shared.get_response else set_response);
                const after = std.Io.Clock.awake.now(shared.io).nanoseconds;
                sample.* = @intCast(after - before);
            }
        } else {
            var pipeline = Pipeline{
                .worker = self,
                .writer = &writer,
                .reader = &reader,
                .get_request = get_request,
                .set_request = set_request,
            };
            // Carries completion or failure from each concurrently running pipeline side.
            const Result = union(enum) {
                // Result from writing and flushing the current request batches.
                write: anyerror!void,
                // Result from consuming and validating the corresponding responses.
                read: anyerror!void,
            };
            var results: [2]Result = undefined;
            var select = std.Io.Select(Result).init(shared.io, &results);
            defer select.cancelDiscard();
            try select.concurrent(.read, Pipeline.read, .{&pipeline});
            try select.concurrent(.write, Pipeline.write, .{&pipeline});
            self.announceReady();
            announced = true;
            for (0..2) |_| switch (try select.await()) {
                .read => |result| try result,
                .write => |result| try result,
            };
        }
        self.finished_ns = std.Io.Clock.awake.now(shared.io).nanoseconds;
    }

    /// Adds this worker to the readiness barrier and opens it for the final participant.
    fn announceReady(self: *Worker) void {
        if (self.shared.ready_count.fetchAdd(1, .acq_rel) + 1 == self.shared.count) {
            self.shared.ready.set(self.shared.io);
        }
    }
};

/// Drives the write and read sides of one client's pipelined workload.
const Pipeline = struct {
    /// Client that owns the connection and sample storage.
    worker: *Worker,
    /// Buffered socket writer shared by the write task.
    writer: *std.Io.net.Stream.Writer,
    /// Buffered socket reader shared by the read task.
    reader: *std.Io.net.Stream.Reader,
    /// Encoded GET command used for selected requests.
    get_request: []const u8,
    /// Encoded SET command used for selected requests.
    set_request: []const u8,
    /// Signals that a batch's timing window and response reads may begin.
    started: std.Io.Event = .unset,
    /// Signals that the current batch has been consumed and the next may be sent.
    completed: std.Io.Event = .unset,
    /// Awake-clock start timestamp for the current batch.
    before: i96 = 0,

    /// Emits each bounded batch, measuring from before its first write.
    fn write(self: *Pipeline) !void {
        const shared = self.worker.shared;
        try shared.start.wait(shared.io);
        var offset: usize = 0;
        while (offset < shared.options.requests) {
            const count = @min(shared.options.pipeline, shared.options.requests - offset);
            self.before = std.Io.Clock.awake.now(shared.io).nanoseconds;
            self.started.set(shared.io);
            for (offset..offset + count) |i| {
                try self.writer.interface.writeAll(if (isGet(shared.scenario, i)) self.get_request else self.set_request);
            }
            try self.writer.interface.flush();
            try self.completed.wait(shared.io);
            self.completed.reset();
            offset += count;
        }
    }

    /// Consumes each batch's responses and stores whole-batch elapsed nanoseconds.
    fn read(self: *Pipeline) !void {
        const shared = self.worker.shared;
        var offset: usize = 0;
        for (self.worker.samples) |*sample| {
            try self.started.wait(shared.io);
            self.started.reset();
            const count = @min(shared.options.pipeline, shared.options.requests - offset);
            for (offset..offset + count) |i| {
                try expectResponse(self.reader, if (isGet(shared.scenario, i)) shared.get_response else set_response);
            }
            sample.* = @intCast(std.Io.Clock.awake.now(shared.io).nanoseconds - self.before);
            self.completed.set(shared.io);
            offset += count;
        }
    }
};

/// Runs one scenario across the requested client count and prints its measurements.
/// Setup, arithmetic overflow, connection, protocol, and timing failures are returned.
fn runScenario(io: std.Io, options: Options, scenario: Scenario, count: usize) !void {
    const allocator = std.heap.page_allocator;
    const total = try std.math.mul(usize, options.requests, count);
    if (total > std.math.maxInt(usize) / 100) return error.TooManyRequests;
    const batches_per_client = (options.requests - 1) / options.pipeline + 1;
    const samples = try allocator.alloc(u64, try std.math.mul(usize, batches_per_client, count));
    defer allocator.free(samples);
    const value = try allocator.alloc(u8, options.value_size);
    defer allocator.free(value);
    for (value, 0..) |*byte, i| byte.* = @as(u8, @intCast(i % 26)) + 'a';
    const get_response = try std.fmt.allocPrint(allocator, "${d}\r\n{s}\r\n\x03", .{ value.len, value });
    defer allocator.free(get_response);
    var shared = Shared{
        .io = io,
        .address = try std.Io.net.IpAddress.parse(options.host, options.port),
        .scenario = scenario,
        .count = count,
        .options = options,
        .value = value,
        .get_response = get_response,
    };
    const workers = try allocator.alloc(Worker, count);
    defer allocator.free(workers);
    const threads = try allocator.alloc(std.Thread, count);
    defer allocator.free(threads);
    var spawned: usize = 0;
    errdefer {
        shared.start.set(io);
        for (threads[0..spawned]) |thread| thread.join();
    }
    for (0..count) |i| {
        workers[i] = .{ .shared = &shared, .id = i, .samples = samples[i * batches_per_client ..][0..batches_per_client] };
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{&workers[i]});
        spawned += 1;
    }
    shared.ready.waitUncancelable(io);
    const start_ns = std.Io.Clock.awake.now(io).nanoseconds;
    shared.start.set(io);
    for (threads[0..spawned]) |thread| thread.join();
    spawned = 0;

    var end_ns = start_ns;
    for (workers[0..count]) |worker| {
        if (worker.result) |err| return err;
        end_ns = @max(end_ns, worker.finished_ns);
    }
    const elapsed_ns = end_ns - start_ns;
    if (elapsed_ns <= 0) return error.InvalidElapsedTime;
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    const throughput = @as(f64, @floatFromInt(total)) * 1_000_000_000.0 / @as(f64, @floatFromInt(elapsed_ns));
    const value_mib_per_second = throughput * @as(f64, @floatFromInt(options.value_size)) / (1024 * 1024);
    std.debug.print("| {s} | {d} | {d} | {d} | {d} | {d:.0} | {d:.2} | {d:.2} | {d:.2} | {d:.2} |\n", .{
        @tagName(scenario),                                        count,                                                     options.pipeline,                                          options.value_size, total, throughput, value_mib_per_second,
        @as(f64, @floatFromInt(percentile(samples, 50))) / 1000.0, @as(f64, @floatFromInt(percentile(samples, 95))) / 1000.0, @as(f64, @floatFromInt(percentile(samples, 99))) / 1000.0,
    });
}

/// Parses arguments, selects scenarios, and prints the benchmark results table.
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(std.heap.page_allocator);
    defer std.heap.page_allocator.free(args);
    const options = parseOptions(args) catch |err| {
        std.debug.print("Usage: benchmark --mode ram|persistence [--host IP] [--port PORT] [--requests EVEN_PER_CLIENT] [--clients 1..128] [--pipeline 1..4096] [--value-size 1..1048576]\n", .{});
        return err;
    };
    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    std.debug.print("Latency measures a whole batch, not an individual pipelined request. Value MiB/s excludes protocol overhead.\n", .{});
    std.debug.print("| Scenario | Clients | Pipeline | Value B | Requests | ops/s | Value MiB/s | Batch P50 us | Batch P95 us | Batch P99 us |\n| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n", .{});
    const scenarios: []const Scenario = if (options.mode == .ram) &.{ .get, .set, .mixed } else &.{.persistence};
    for (scenarios) |scenario| {
        if (options.clients) |count| {
            try runScenario(io, options, scenario, count);
        } else {
            for (client_counts) |count| try runScenario(io, options, scenario, count);
        }
    }
}
