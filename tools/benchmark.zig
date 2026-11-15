const std = @import("std");
const consts = @import("consts.zig");

const MAX_WORKERS = 8;
const ITERATIONS = 10000;

fn randomString(io: std.Io, comptime len: usize) [len]u8 {
    const seed: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    var result: [len]u8 = undefined;

    for (&result) |*byte| {
        const random_byte: u8 = @intCast(rand.int(u8) % 26);
        byte.* = @intCast(97 + random_byte);
    }
    return result;
}

fn runCommandFmt(
    writer: *std.Io.net.Stream.Writer,
    reader: *std.Io.net.Stream.Reader,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    try writer.interface.print(fmt, args);
    try writer.interface.writeAll("\x03");
    try writer.interface.flush();
    _ = try reader.interface.discardDelimiterInclusive(consts.EXT_CHAR);
}

fn worker(io: std.Io) !void {
    const address = try std.Io.net.IpAddress.parse(consts.HOST, consts.PORT);
    const socket = try address.connect(io, .{ .mode = .stream });
    defer socket.close(io);

    var writer_buffer: [1024]u8 = undefined;
    var reader_buffer: [1024]u8 = undefined;
    var writer = socket.writer(io, &writer_buffer);
    var reader = socket.reader(io, &reader_buffer);

    for (0..ITERATIONS) |_| {
        const key = randomString(io, 10);
        const value = randomString(io, 20);

        try runCommandFmt(
            &writer,
            &reader,
            "*3\r\n$3\r\nset\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n",
            .{ key.len, key, value.len, value },
        );

        try runCommandFmt(
            &writer,
            &reader,
            "*2\r\n$3\r\nget\r\n${d}\r\n{s}\r\n",
            .{ key.len, key },
        );
    }
}

pub fn main() !void {
    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const start_time = std.Io.Clock.awake.now(io).toMilliseconds();

    var workers: [MAX_WORKERS]std.Thread = undefined;

    for (0..MAX_WORKERS) |i| workers[i] = try std.Thread.spawn(
        .{},
        worker,
        .{io},
    );

    for (workers) |worker_thread| worker_thread.join();

    const end_time = std.Io.Clock.awake.now(io).toMilliseconds();
    const elapsed_ms = end_time - start_time;

    const elapsed_s = @as(f64, @floatFromInt(elapsed_ms)) / 1000;

    const total_requests = (MAX_WORKERS * ITERATIONS) * 2; // times 2 cuz we have 2 commands to send.
    const requests_per_second = @as(f64, @floatFromInt(total_requests)) / elapsed_s;

    std.debug.print("Total Requests: {d}\n", .{total_requests});
    std.debug.print("Elapsed Time: {d} ms\n", .{elapsed_ms});
    std.debug.print("Requests per Second: {d}\n", .{requests_per_second});
}
