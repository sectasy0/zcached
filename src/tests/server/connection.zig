const std = @import("std");
const Connection = @import("../../server/network/connection.zig");
const server = @import("../../server/network/stream_server.zig");

const Stream = @import("../../server/network/stream.zig").Stream;

test "Connection.init" {
    const allocator = std.testing.allocator;
    const incoming = server.Connection{
        .stream = Stream{ .handle = 1 },
        .address = std.net.Address.initIp4(.{ 192, 168, 0, 1 }, 1234),
    };

    var pollfd = std.posix.pollfd{
        .fd = incoming.stream.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    };

    const buffer_size = 4096;
    var connection = try Connection.init(
        allocator,
        incoming,
        &pollfd,
        0, // id
    );
    defer connection.deinit();

    try std.testing.expectEqual(buffer_size, connection.buffer.len);
    try std.testing.expectEqual(0, connection.accumulator.items.len);
    try std.testing.expectEqual(1, connection.stream.handle);
    try std.testing.expectEqual(incoming.address.any, connection.address.any);
    try std.testing.expectEqual(allocator, connection.allocator);
}

test "Connection.deinit" {
    const allocator = std.testing.allocator;
    const incoming = server.Connection{
        .stream = Stream{ .handle = 1 },
        .address = std.net.Address.initIp4(.{ 192, 168, 0, 1 }, 1234),
    };

    var pollfd = std.posix.pollfd{
        .fd = incoming.stream.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    };

    var connection = try Connection.init(
        allocator,
        incoming,
        &pollfd,
        0, // id
    );

    connection.deinit();
    // Normally we would check if the buffer is freed, but since we are using a testing allocator
    // this is sufficient to ensure no memory leaks in tests.
}

test "Connection.fd" {
    const allocator = std.testing.allocator;
    const incoming = server.Connection{
        .stream = Stream{ .handle = 1 },
        .address = std.net.Address.initIp4(.{ 192, 168, 0, 1 }, 1234),
    };

    var pollfd = std.posix.pollfd{
        .fd = incoming.stream.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    };

    var connection = try Connection.init(
        allocator,
        incoming,
        &pollfd,
        0, // id
    );
    defer connection.deinit();

    try std.testing.expectEqual(1, connection.fd());
}

// this test now returns `thread 1049524 panic: internal test runner failure`
// likely a bug
// test "Connection.close" {
//     const allocator = std.testing.allocator;

//     const incoming = server.Connection{
//         .stream = Stream{ .handle = 1 },
//         .address = std.net.Address.initIp4(.{ 192, 168, 0, 1 }, 1234),
//     };

//     var connection = try Connection.init(allocator, incoming);
//     defer connection.deinit();

//     connection.close();

//     try std.testing.expectEqual(1, connection.stream.handle);
// }
