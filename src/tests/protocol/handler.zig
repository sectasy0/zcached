const std = @import("std");

const ProtocolHandlerT = @import("../../protocol/handler.zig").ProtocolHandlerT;
const types = @import("../../protocol/types.zig");

test "serialize" {
    var stream = std.io.fixedBufferStream("*3\r\n$3\r\nSET\r\n$9\r\nmycounter\r\n:42\r\n");

    const reader = stream.reader();

    const HandlerType = ProtocolHandlerT(*const @TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    const result = try handler.serialize(&reader);
    const result_array = result.array.items;
    try std.testing.expectEqualStrings("SET", result_array[0].str);
    try std.testing.expectEqualStrings("mycounter", result_array[1].str);
    try std.testing.expectEqual(42, result_array[2].int);
}

test "deserialize" {
    var array = try std.array_list.Managed(types.ZType).initCapacity(std.testing.allocator, 3);
    defer array.deinit();

    try array.append(.{ .str = "first" });
    try array.append(.{ .str = "second" });
    try array.append(.{ .str = "third" });

    const HandlerType = ProtocolHandlerT(*const std.net.Stream.Reader);
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    const result = try handler.deserialize(.{ .array = array });
    const expected = "*3\r\n$5\r\nfirst\r\n$6\r\nsecond\r\n$5\r\nthird\r\n";
    try std.testing.expectEqualStrings(expected, result);
}
