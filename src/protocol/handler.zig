//! Combines protocol parsing and encoding behind a single reusable handler.

const std = @import("std");
const os = std.os;

const types = @import("types.zig");
const SerializerT = @import("serializer.zig").SerializerT;
const Deserializer = @import("deserializer.zig").Deserializer;
const fixed_buffer_stream = @import("fixed_buffer_stream.zig");

/// Handler specialized for the project's fixed-buffer reader.
pub const ProtocolHandler = ProtocolHandlerT(fixed_buffer_stream.FixedBufferStream.Reader);

/// Builds a handler for a reader type accepted by the protocol serializer.
pub fn ProtocolHandlerT(comptime GenericReader: type) type {
    return struct {
        const Self = @This();

        const Serializer = SerializerT(GenericReader);
        /// Parses incoming wire data using the configured reader type.
        serializer: Serializer,
        /// Encodes typed values into protocol wire data.
        deserializer: Deserializer,

        /// Allocator borrowed by both codec components for their internal storage.
        allocator: std.mem.Allocator,

        /// Creates the codecs using `allocator`; initialization can fail on allocation.
        pub fn init(allocator: std.mem.Allocator) !Self {
            return Self{
                .serializer = try Serializer.init(allocator),
                .deserializer = Deserializer.init(allocator),
                .allocator = allocator,
            };
        }

        /// Parses the next value from `reader`, retaining parsed data until reset.
        pub fn serialize(self: *Self, reader: GenericReader) !types.ZType {
            return self.serializer.process(reader);
        }

        /// Encodes `value`; the returned bytes remain valid until reset or deinit.
        pub fn deserialize(self: *Self, value: types.ZType) anyerror![]const u8 {
            return self.deserializer.process(value);
        }

        /// Releases accumulated parse and output data while keeping capacity reusable.
        pub fn reset(self: *Self) void {
            self.serializer.reset();
            self.deserializer.reset();
        }

        /// Releases the serializer and deserializer storage.
        pub fn deinit(self: *Self) void {
            self.serializer.deinit();
            self.deserializer.deinit();
        }
    };
}
