const std = @import("std");
const Address = @import("../../server/network/address.zig").Address;
const StreamServer = @import("../../server/network/stream_server.zig");
const Stream = @import("../../server/network/stream.zig").StreamT(false);

test "StreamServer listens on an ephemeral port and closes cleanly" {
    var server = try StreamServer.init(std.testing.io, .{ .reuse_address = true });
    defer server.deinit();

    try server.listen(Address.initIp4(.{ 127, 0, 0, 1 }, 0));

    try std.testing.expect(server.listener != null);
    try std.testing.expect(server.listen_address.getPort() != 0);

    server.close();
    try std.testing.expect(server.listener == null);
}

test "Stream reader keeps pipelined frames buffered and reports transport errors" {
    const io = std.testing.io;
    var server = try StreamServer.init(io, .{});
    defer server.deinit();
    try server.listen(Address.initIp4(.{ 127, 0, 0, 1 }, 0));
    const client = try server.listen_address.ip.connect(io, .{ .mode = .stream });
    defer client.close(io);
    var incoming = try server.accept(io);
    defer incoming.stream.close();
    var writer = client.writer(io, &.{});
    try writer.interface.writeAll("first\x03second\x03");

    var buffer: [64]u8 = undefined;
    var reader = incoming.stream.reader(&buffer);
    try std.testing.expectEqualStrings("first\x03", try reader.interface.takeDelimiterInclusive('\x03'));
    try std.testing.expectEqualStrings("second\x03", try reader.interface.takeDelimiterInclusive('\x03'));

    incoming.stream.close();
    try std.testing.expectError(error.ReadFailed, reader.interface.takeDelimiterInclusive('\x03'));
    try std.testing.expectEqual(error.StreamClosed, reader.err.?);
}

test "Stream uses supplied IO for reads and writes" {
    const Probe = struct {
        reads: usize = 0,
        writes: usize = 0,

        fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            return switch (operation) {
                .net_read => blk: {
                    self.reads += 1;
                    break :blk .{ .net_read = error.SocketUnconnected };
                },
                .net_write => blk: {
                    self.writes += 1;
                    break :blk .{ .net_write = error.SocketUnconnected };
                },
                else => unreachable,
            };
        }
    };
    var probe: Probe = .{};
    var vtable = std.testing.io.vtable.*;
    vtable.operate = Probe.operate;
    var stream: Stream = .{
        .io = .{ .userdata = &probe, .vtable = &vtable },
        .socket = .{ .socket = .{ .handle = 1, .address = .{ .ip4 = .loopback(1234) } } },
    };
    var buffer: [8]u8 = undefined;
    try std.testing.expectError(error.SocketUnconnected, stream.read(&buffer));
    try std.testing.expectError(error.SocketUnconnected, stream.write("test"));
    try std.testing.expectEqual(@as(usize, 1), probe.reads);
    try std.testing.expectEqual(@as(usize, 1), probe.writes);
}
