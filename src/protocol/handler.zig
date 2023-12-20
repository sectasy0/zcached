const os = @import("std").os;
const std = @import("std");

const types = @import("types.zig");
const SerializerT = @import("serializer.zig").SerializerT;
const Deserializer = @import("deserializer.zig").Deserializer;

pub const ProtocolHandler = ProtocolHandlerT(*const std.net.Stream.Reader);
fn ProtocolHandlerT(comptime GenericReader: type) type {
    return struct {
        const Self = @This();

        const Serializer = SerializerT(GenericReader);
        serializer: Serializer,

        deserializer: Deserializer,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) !Self {
            return Self{
                .serializer = try Serializer.init(allocator),
                .deserializer = Deserializer.init(allocator),
                .allocator = allocator,
            };
        }

        pub fn serialize(self: *Self, reader: GenericReader) !types.AnyType {
            return self.serializer.process(reader);
        }

        pub fn deserialize(self: *Self, value: types.AnyType) anyerror![]const u8 {
            return self.deserializer.process(value);
        }

        pub fn repr(self: *Self, value: []const u8) ![]const u8 {
            const size = std.mem.replacementSize(u8, value, "\r\n", "\\r\\n");
            var output = try self.allocator.alloc(u8, size);
            _ = std.mem.replace(u8, value, "\r\n", "\\r\\n", output);
            return output;
        }

        pub fn deinit(self: *Self) void {
            self.serializer.deinit();
            self.deserializer.deinit();
        }
    };
}

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
    var array = std.ArrayList(types.AnyType).init(std.testing.allocator);
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
