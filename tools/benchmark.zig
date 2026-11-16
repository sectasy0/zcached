const std = @import("std");
const consts = @import("consts.zig");

const client_counts = [_]usize{ 1, 2, 4, 8, 16 };
const value = "abcdefghijklmnopqrst";
const get_response = "$20\r\n" ++ value ++ "\r\n\x03";
const set_response = "+OK\r\n\x03";

const Mode = enum { ram, persistence };
const Scenario = enum { get, set, mixed, persistence };

const Options = struct {
    host: []const u8 = consts.HOST,
    port: u16 = consts.PORT,
    requests: usize = 10000,
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
    const response = try reader.interface.takeDelimiterInclusive(consts.EXT_CHAR);
    if (!std.mem.eql(u8, response, expected)) {
        std.debug.print("Unexpected server response: {s}\n", .{response});
        return error.UnexpectedResponse;
    }
}

const Shared = struct {
    io: std.Io,
    address: std.Io.net.IpAddress,
    scenario: Scenario,
    count: usize,
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
        var writer_buffer: [1024]u8 = undefined;
        var reader_buffer: [1024]u8 = undefined;
        var writer = socket.writer(shared.io, &writer_buffer);
        var reader = socket.reader(shared.io, &reader_buffer);

        var key_buffer: [64]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buffer, "__zcached_benchmark_{d}__", .{self.id});
        var set_buffer: [256]u8 = undefined;
        const set_request = try std.fmt.bufPrint(&set_buffer, "*3\r\n$3\r\nSET\r\n${d}\r\n{s}\r\n$20\r\n{s}\r\n\x03", .{ key.len, key, value });
        var get_buffer: [256]u8 = undefined;
        const get_request = try std.fmt.bufPrint(&get_buffer, "*2\r\n$3\r\nGET\r\n${d}\r\n{s}\r\n\x03", .{ key.len, key });

        try command(&writer, &reader, set_request, set_response);
        self.announceReady();
        announced = true;
        shared.start.waitUncancelable(shared.io);

        for (self.samples, 0..) |*sample, i| {
            const get = isGet(shared.scenario, i);
            const before = std.Io.Clock.awake.now(shared.io).nanoseconds;
            try command(&writer, &reader, if (get) get_request else set_request, if (get) get_response else set_response);
            const after = std.Io.Clock.awake.now(shared.io).nanoseconds;
            sample.* = @intCast(after - before);
        }
        self.finished_ns = std.Io.Clock.awake.now(shared.io).nanoseconds;
    }

    fn announceReady(self: *Worker) void {
        if (self.shared.ready_count.fetchAdd(1, .acq_rel) + 1 == self.shared.count) {
            self.shared.ready.set(self.shared.io);
        }
    }
};

fn runScenario(io: std.Io, options: Options, scenario: Scenario, count: usize) !void {
    const allocator = std.heap.page_allocator;
    const total = try std.math.mul(usize, options.requests, count);
    if (total > std.math.maxInt(usize) / 100) return error.TooManyRequests;
    const samples = try allocator.alloc(u64, total);
    defer allocator.free(samples);
    var shared = Shared{
        .io = io,
        .address = try std.Io.net.IpAddress.parse(options.host, options.port),
        .scenario = scenario,
        .count = count,
    };
    var workers: [16]Worker = undefined;
    var threads: [16]std.Thread = undefined;
    var spawned: usize = 0;
    errdefer {
        shared.start.set(io);
        for (threads[0..spawned]) |thread| thread.join();
    }
    for (0..count) |i| {
        workers[i] = .{ .shared = &shared, .id = i, .samples = samples[i * options.requests ..][0..options.requests] };
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
    std.debug.print("| {s} | {d} | {d} | {d:.0} | {d:.2} | {d:.2} | {d:.2} |\n", .{
        @tagName(scenario),                                        count,                                                     total,                                                     throughput,
        @as(f64, @floatFromInt(percentile(samples, 50))) / 1000.0, @as(f64, @floatFromInt(percentile(samples, 95))) / 1000.0, @as(f64, @floatFromInt(percentile(samples, 99))) / 1000.0,
    });
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(std.heap.page_allocator);
    defer std.heap.page_allocator.free(args);
    const options = parseOptions(args) catch |err| {
        std.debug.print("Usage: benchmark --mode ram|persistence [--host IP] [--port PORT] [--requests EVEN_PER_CLIENT]\n", .{});
        return err;
    };
    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    std.debug.print("| Scenario | Clients | Requests | ops/s | P50 us | P95 us | P99 us |\n| --- | ---: | ---: | ---: | ---: | ---: | ---: |\n", .{});
    const scenarios: []const Scenario = if (options.mode == .ram) &.{ .get, .set, .mixed } else &.{.persistence};
    for (scenarios) |scenario| {
        for (client_counts) |count| try runScenario(io, options, scenario, count);
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
