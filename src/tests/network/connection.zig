const std = @import("std");
const runtime_io = @import("runtime_io");
const Address = @import("../../server/network/address.zig").Address;
const Connection = @import("../../server/network/connection.zig");
const StreamServer = @import("../../server/network/stream_server.zig");

test "Connection enforces the request size before accumulating bytes" {
    const io = runtime_io.get();
    var server = try StreamServer.init(io, .{});
    defer server.deinit();
    try server.listen(Address.initIp4(.{ 127, 0, 0, 1 }, 0));
    const client = try server.listen_address.ip.connect(io, .{ .mode = .stream });
    defer client.close(io);
    var incoming = try server.accept(io);
    defer incoming.stream.close();
    var connection = try Connection.init(std.testing.allocator, incoming);
    defer connection.deinit();

    var writer = client.writer(io, &.{});
    try writer.interface.writeAll("abc\x03");
    try connection.readPending(4);
    try std.testing.expectEqualStrings("abc\x03", connection.accumulator.items);

    try writer.interface.writeAll("x");
    try std.testing.expectError(error.MessageTooLarge, connection.readPending(4));
    try std.testing.expectEqualStrings("abc\x03", connection.accumulator.items);
}

test "Connection flushes responses larger than the old write chunk" {
    const io = runtime_io.get();
    var server = try StreamServer.init(io, .{});
    defer server.deinit();
    try server.listen(Address.initIp4(.{ 127, 0, 0, 1 }, 0));
    const client = try server.listen_address.ip.connect(io, .{ .mode = .stream });
    defer client.close(io);
    var incoming = try server.accept(io);
    defer incoming.stream.close();
    var connection = try Connection.init(std.testing.allocator, incoming);
    defer connection.deinit();

    const response: [16384]u8 = @splat('x');
    try connection.out().writeAll(&response);
    try connection.writePending();
    var reader = client.reader(io, &.{});
    var received: [response.len]u8 = undefined;
    try reader.interface.readSliceAll(&received);
    try std.testing.expectEqualSlices(u8, &response, &received);
    try std.testing.expectEqual(@as(usize, 0), connection.tx_accumulator.items.len);
}
