const std = @import("std");
const Address = @import("../../server/network/address.zig").Address;
const StreamServer = @import("../../server/network/stream_server.zig");

test "StreamServer listens on an ephemeral port and closes cleanly" {
    var server = try StreamServer.init(.{ .reuse_address = true });
    defer server.deinit();

    try server.listen(Address.initIp4(.{ 127, 0, 0, 1 }, 0));

    try std.testing.expect(server.listener != null);
    try std.testing.expect(server.listen_address.getPort() != 0);

    server.close();
    try std.testing.expect(server.listener == null);
}

test "Stream reader keeps pipelined frames buffered and reports transport errors" {
    const io = std.testing.io;
    var server = try StreamServer.init(.{});
    defer server.deinit();
    try server.listen(Address.initIp4(.{ 127, 0, 0, 1 }, 0));
    const client = try server.listen_address.ip.connect(io, .{ .mode = .stream });
    defer client.close(io);
    var incoming = try server.accept();
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
