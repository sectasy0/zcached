const std = @import("std");
const Reactor = @import("runtime_io").Evented.Reactor;
const Key = Reactor.Key;
const init = Reactor.init;

/// Creates a pipe for reactor tests, returning native errors as Zig errors.
fn testPipe() ![2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    return fds;
}

test "one-shot duplicate arm, rearm, disarm, and EOF" {
    var reactor = try init(std.testing.allocator);
    defer reactor.deinit();
    const fds = try testPipe();
    defer _ = std.c.close(fds[0]);
    var writer_open = true;
    defer if (writer_open) {
        _ = std.c.close(fds[1]);
    };
    const key: Key = .{ .fd = fds[0], .interest = .read };
    var events: [4]Key = undefined;
    try reactor.arm(key);
    try reactor.arm(key);
    try std.testing.expectEqual(@as(usize, 0), try reactor.wait(&events, 0));
    try std.testing.expectEqual(@as(isize, 1), std.c.write(fds[1], "x", 1));
    try std.testing.expectEqual(@as(usize, 1), try reactor.wait(&events, std.time.ns_per_s));
    try std.testing.expectEqual(key, events[0]);
    try std.testing.expectEqual(@as(usize, 0), try reactor.wait(&events, 0));
    try reactor.arm(key);
    try reactor.disarm(key);
    try std.testing.expectEqual(@as(usize, 0), try reactor.wait(&events, 0));
    try reactor.arm(key);
    try std.testing.expectEqual(@as(usize, 1), try reactor.wait(&events, std.time.ns_per_s));
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 1), std.c.read(fds[0], &byte, 1));
    _ = std.c.close(fds[1]);
    writer_open = false;
    try reactor.arm(key);
    try std.testing.expectEqual(@as(usize, 1), try reactor.wait(&events, std.time.ns_per_s));
    try std.testing.expectEqual(@as(isize, 0), std.c.read(fds[0], &byte, 1));
}

test "bounded wait and output capacity preserve watches" {
    var reactor = try init(std.testing.allocator);
    defer reactor.deinit();
    const fds = try testPipe();
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    const read: Key = .{ .fd = fds[0], .interest = .read };
    const write: Key = .{ .fd = fds[1], .interest = .write };
    var events: [1]Key = undefined;
    try reactor.arm(read);
    const start = std.Io.Clock.awake.now(std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), try reactor.wait(&events, 5 * std.time.ns_per_ms));
    const elapsed = start.durationTo(std.Io.Clock.awake.now(std.testing.io)).nanoseconds;
    try std.testing.expect(elapsed >= 5 * std.time.ns_per_ms);
    try std.testing.expect(elapsed < std.time.ns_per_s);
    try reactor.arm(write);
    try std.testing.expectEqual(@as(isize, 1), std.c.write(fds[1], "x", 1));
    try std.testing.expectEqual(@as(usize, 1), try reactor.wait(&events, std.time.ns_per_s));
    const first = events[0];
    try std.testing.expectEqual(@as(usize, 1), try reactor.wait(&events, std.time.ns_per_s));
    try std.testing.expect(first.interest != events[0].interest);
    try std.testing.expectEqual(@as(usize, 0), try reactor.wait(&events, 0));
}

test "rapid cancellation generations never deliver an old watch" {
    var reactor = try init(std.testing.allocator);
    defer reactor.deinit();
    const fds = try testPipe();
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    const key: Key = .{ .fd = fds[0], .interest = .read };
    for (0..600) |_| {
        try reactor.arm(key);
        try reactor.disarm(key);
    }
    try reactor.arm(key);
    try std.testing.expectEqual(@as(isize, 1), std.c.write(fds[1], "x", 1));
    var events: [1]Key = undefined;
    try std.testing.expectEqual(@as(usize, 1), try reactor.wait(&events, std.time.ns_per_s));
    try std.testing.expectEqual(key, events[0]);
    try std.testing.expectEqual(@as(usize, 0), try reactor.wait(&events, 0));
}
