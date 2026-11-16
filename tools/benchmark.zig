const std = @import("std");
const consts = @import("consts.zig");

const client_counts = [_]usize{ 1, 2, 4, 8, 16 };
const set_response = "+OK\r\n\x03";

const Mode = enum { ram, persistence };
const Scenario = enum { get, set, mixed, persistence };

const Options = struct {
    host: []const u8 = consts.HOST,
    port: u16 = consts.PORT,
    requests: usize = 10000,
    pipeline: usize = 1,
    value_size: usize = 20,
    clients: ?usize = null,
    mode: Mode,
};

fn parseOptions(args: []const [:0]const u8) !Options {
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

fn isGet(scenario: Scenario, index: usize) bool {
    return scenario == .get or (scenario == .mixed and index % 2 == 0);
}

fn percentile(sorted: []const u64, percent: usize) u64 {
    // Nearest-rank percentile, with one-based ranks.
    const rank = (sorted.len * percent + 99) / 100;
    return sorted[rank - 1];
}

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

fn expectResponse(reader: *std.Io.net.Stream.Reader, expected: []const u8) !void {
    const response = try reader.interface.takeDelimiterInclusive(consts.EXT_CHAR);
    if (!std.mem.eql(u8, response, expected)) {
        std.debug.print("Unexpected server response (first 256 bytes): {s}\n", .{response[0..@min(response.len, 256)]});
        return error.UnexpectedResponse;
    }
}

const Shared = struct {
    io: std.Io,
    address: std.Io.net.IpAddress,
    scenario: Scenario,
    count: usize,
    options: Options,
    value: []const u8,
    get_response: []const u8,
    ready_count: std.atomic.Value(usize) = .init(0),
    ready: std.Io.Event = .unset,
    start: std.Io.Event = .unset,
};

const Worker = struct {
    shared: *Shared,
    id: usize,
    samples: []u64,
    result: ?anyerror = null,
    finished_ns: i96 = 0,

    fn run(self: *Worker) void {
        self.execute() catch |err| {
            self.result = err;
        };
    }

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
            const Result = union(enum) { write: anyerror!void, read: anyerror!void };
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

    fn announceReady(self: *Worker) void {
        if (self.shared.ready_count.fetchAdd(1, .acq_rel) + 1 == self.shared.count) {
            self.shared.ready.set(self.shared.io);
        }
    }
};

const Pipeline = struct {
    worker: *Worker,
    writer: *std.Io.net.Stream.Writer,
    reader: *std.Io.net.Stream.Reader,
    get_request: []const u8,
    set_request: []const u8,
    started: std.Io.Event = .unset,
    completed: std.Io.Event = .unset,
    before: i96 = 0,

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

test "benchmark parses pipelining payload size and custom client count" {
    const options = try parseOptions(&.{ "benchmark", "--mode", "ram", "--pipeline", "64", "--value-size", "16384", "--clients", "32", "--requests", "10002" });
    try std.testing.expectEqual(@as(usize, 64), options.pipeline);
    try std.testing.expectEqual(@as(usize, 16384), options.value_size);
    try std.testing.expectEqual(@as(?usize, 32), options.clients);
    try std.testing.expectEqual(@as(usize, 10002), options.requests);
    for ([_][:0]const u8{ "0", "4097" }) |value| {
        try std.testing.expectError(error.InvalidPipeline, parseOptions(&.{ "benchmark", "--mode", "ram", "--pipeline", value }));
    }
    for ([_][:0]const u8{ "0", "1048577" }) |value| {
        try std.testing.expectError(error.InvalidValueSize, parseOptions(&.{ "benchmark", "--mode", "ram", "--value-size", value }));
    }
    for ([_][:0]const u8{ "0", "129" }) |value| {
        try std.testing.expectError(error.InvalidClientCount, parseOptions(&.{ "benchmark", "--mode", "ram", "--clients", value }));
    }
}

test "mixed workload is exactly balanced" {
    var gets: usize = 0;
    for (0..100) |i| gets += @intFromBool(isGet(.mixed, i));
    try std.testing.expectEqual(50, gets);
    try std.testing.expect(isGet(.get, 1));
    try std.testing.expect(!isGet(.set, 0));
    try std.testing.expect(!isGet(.persistence, 0));
}

test "nearest-rank latency percentiles" {
    const samples = [_]u64{ 1, 2, 3, 4, 5 };
    try std.testing.expectEqual(3, percentile(&samples, 50));
    try std.testing.expectEqual(5, percentile(&samples, 95));
    try std.testing.expectEqual(5, percentile(&samples, 99));
}

test "benchmark options require mode and an even request count" {
    try std.testing.expectError(error.MissingMode, parseOptions(&.{"benchmark"}));
    try std.testing.expectError(error.InvalidRequestCount, parseOptions(&.{ "benchmark", "--mode", "ram", "--requests", "3" }));
    try std.testing.expectError(error.InvalidMode, parseOptions(&.{ "benchmark", "--mode", "other" }));
    const options = try parseOptions(&.{ "benchmark", "--mode", "persistence", "--port", "1234", "--requests", "2" });
    try std.testing.expectEqual(Mode.persistence, options.mode);
    try std.testing.expectEqual(1234, options.port);
    try std.testing.expectEqual(2, options.requests);
}
