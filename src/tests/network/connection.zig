const std = @import("std");
const runtime_io = @import("runtime_io");
const Address = @import("../../server/network/address.zig").Address;
const Connection = @import("../../server/network/connection.zig");
const StreamServer = @import("../../server/network/stream_server.zig");
const fixtures = @import("../fixtures.zig");

const ReadProbe = struct {
    input: []const u8 = "",
    requested: usize = 0,

    fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
        const self: *@This() = @ptrCast(@alignCast(userdata.?));
        switch (operation) {
            .net_read => |read| {
                const buffer = read.data[0];
                self.requested = buffer.len;
                const count = @min(buffer.len, self.input.len);
                @memcpy(buffer[0..count], self.input[0..count]);
                self.input = self.input[count..];
                return .{ .net_read = .{ .data_len = count } };
            },
            else => unreachable,
        }
    }
};

test "Connection grows full reads from 4 KiB to 64 KiB and reuses the larger chunk" {
    var fixture = try fixtures.ConnectionFixture.init(std.testing.allocator);
    defer fixture.connection.deinit();
    const connection = &fixture.connection;
    var probe: ReadProbe = .{};
    var vtable = std.testing.io.vtable.*;
    vtable.operate = ReadProbe.operate;
    connection.stream.io = .{ .userdata = &probe, .vtable = &vtable };
    var payload: [64 * 1024]u8 = @splat('x');
    for ([_]usize{ 4096, 8192, 16384, 32768, 65536, 65536 }) |size| {
        payload[size - 1] = '\x03';
        probe.input = payload[0..size];
        try connection.readPending(std.math.maxInt(usize));
        try std.testing.expectEqual(size, probe.requested);
        try std.testing.expectEqualSlices(u8, payload[0..size], connection.accumulator.items);
        connection.accumulator.clearRetainingCapacity();
    }
}

test "Connection retains consumed bytes until compaction is needed and limits only unread bytes" {
    var fixture = try fixtures.ConnectionFixture.init(std.testing.allocator);
    defer fixture.connection.deinit();
    const connection = &fixture.connection;
    var probe: ReadProbe = .{ .input = "\x03" };
    var vtable = std.testing.io.vtable.*;
    vtable.operate = ReadProbe.operate;
    connection.stream.io = .{ .userdata = &probe, .vtable = &vtable };

    try connection.accumulator.appendSlice("usedabc");
    connection.receive_start = 4;
    try connection.readPending(4);
    try std.testing.expectEqualStrings("usedabc\x03", connection.accumulator.items);
    try std.testing.expectEqual(@as(usize, 4), connection.receive_start);

    connection.accumulator.clearRetainingCapacity();
    try connection.accumulator.appendNTimes('x', connection.accumulator.capacity - 3);
    connection.receive_start = connection.accumulator.items.len;
    try connection.accumulator.appendSlice("abc");
    probe.input = "\x03";
    try connection.readPending(4);
    try std.testing.expectEqualStrings("abc\x03", connection.accumulator.items);
    try std.testing.expectEqual(@as(usize, 0), connection.receive_start);

    probe.input = "x";
    try std.testing.expectError(error.MessageTooLarge, connection.readPending(4));
    try std.testing.expectEqualStrings("abc\x03", connection.accumulator.items);
}

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

test "Connection accumulates fragmented requests directly into its buffer" {
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
    try writer.interface.writeAll("abc");
    try std.testing.expectError(error.IncompleteMessage, connection.readPending(4));
    try std.testing.expectEqualStrings("abc", connection.accumulator.items);

    try writer.interface.writeAll("\x03");
    try connection.readPending(4);
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
