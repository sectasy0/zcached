const std = @import("std");

const ProtocolHandlerT = @import("../../src/protocol/handler.zig").ProtocolHandlerT;
const types = @import("../../src/protocol/types.zig");
const SerializerT = @import("../../src/protocol/serializer.zig").SerializerT;
const Deserializer = @import("../../src/protocol/deserializer.zig").Deserializer;

test "serialize" {
    var stream = std.io.fixedBufferStream("*3\r\n$3\r\nSET\r\n$9\r\nmycounter\r\n:42\r\n");

    const reader = stream.reader();

    const HandlerType = ProtocolHandlerT(*const @TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    var result = try handler.serialize(&reader);
    var result_array = result.array.items;
    try std.testing.expectEqualStrings("SET", result_array[0].str);
    try std.testing.expectEqualStrings("mycounter", result_array[1].str);
    try std.testing.expectEqual(.{ .int = 42 }, result_array[2].int);
}

test "deserialize" {
    var array = std.ArrayList(types.ZType).init(std.testing.allocator);
    defer array.deinit();

    try array.append(.{ .str = @constCast("first") });
    try array.append(.{ .str = @constCast("second") });
    try array.append(.{ .str = @constCast("third") });

    const HandlerType = ProtocolHandlerT(*const std.net.Stream.Reader);
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    var result = try handler.deserialize(.{ .array = array });
    const expected = "*3\r\n$5\r\nfirst\r\n$6\r\nsecond\r\n$5\r\nthird\r\n";
    try std.testing.expectEqualStrings(expected, result);
}
