const std = @import("std");
const os = std.os;

const types = @import("types.zig");
const SerializerT = @import("serializer.zig").SerializerT;
const Deserializer = @import("deserializer.zig").Deserializer;

pub const ProtocolHandler = ProtocolHandlerT(*const std.net.Stream.Reader);
pub fn ProtocolHandlerT(comptime GenericReader: type) type {
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

        pub fn serialize(self: *Self, reader: GenericReader) !types.ZType {
            return self.serializer.process(reader);
        }

        pub fn deserialize(self: *Self, value: types.ZType) anyerror![]const u8 {
            return self.deserializer.process(value);
        }

        pub fn deinit(self: *Self) void {
            self.serializer.deinit();
            self.deserializer.deinit();
        }
    };
}
