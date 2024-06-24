const std = @import("std");

const MAX_WORKERS = 8;
const ITERATIONS = 10000;

const HOST = "127.0.0.1";
const PORT = 7556;

fn randomString(comptime len: usize) ![len]u8 {
    var prng = std.rand.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const rand = prng.random();

    // const result = try allocator.alloc(u8, len);
    var result: [len]u8 = undefined;

    for (&result) |*byte| {
        const random_byte: u8 = @intCast(rand.int(u8) % 26);
        byte.* = @intCast(97 + random_byte);
    }
    return result;
}

fn runCommandFmt(socket: *std.net.Stream, comptime fmt: []const u8, args: anytype) !void {
    var bw = std.io.bufferedWriter(socket.writer());
    try std.fmt.format(bw.writer(), fmt, args);
    try bw.flush();
    var buffer: [1024]u8 = undefined;
    const reader = socket.reader();
    _ = try reader.read(buffer[0..]);
}

fn worker() !void {
    const addr = try std.net.Address.parseIp(HOST, PORT);

    var socket = try std.net.tcpConnectToAddress(addr);
    defer socket.close();

    for (0..ITERATIONS) |_| {
        const key = try randomString(10);
        const value = try randomString(20);

        try runCommandFmt(
            &socket,
            "*3\r\n$3\r\nset\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n",
            .{ key.len, key, value.len, value },
        );

        try runCommandFmt(
            &socket,
            "*2\r\n$3\r\nget\r\n${d}\r\n{s}\r\n",
            .{ key.len, key },
        );
    }
}

pub fn main() !void {
    const start_time = std.time.milliTimestamp();

    var workers: [MAX_WORKERS]std.Thread = undefined;

    for (0..MAX_WORKERS) |i| workers[i] = try std.Thread.spawn(
        .{},
        worker,
        .{},
    );

    for (workers) |worker_thread| worker_thread.join();

    const end_time = std.time.milliTimestamp();
    const elapsed_ms = end_time - start_time;

    const elapsed_s = @as(f64, @floatFromInt(elapsed_ms)) / 1000;

    const total_requests = (MAX_WORKERS * ITERATIONS) * 2; // times 2 cuz we have 2 commands to send.
    const requests_per_second = @as(f64, @floatFromInt(total_requests)) / elapsed_s;

    std.debug.print("Total Requests: {d}\n", .{total_requests});
    std.debug.print("Elapsed Time: {d} ms\n", .{elapsed_ms});
    std.debug.print("Requests per Second: {d}\n", .{requests_per_second});
}
