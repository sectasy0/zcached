const std = @import("std");
const os = std.os;

const types = @import("types.zig");
const Config = @import("../server/config.zig");

pub var MAX_BULK_LEN: usize = 0;

const SerializerError = error{
    Unprocessable,
    InvalidType,
    EndOfStream,
    InvalidLength,
    InvalidKey,
    OutOfMemory,
    AllocatorError,
    PayloadExceeded,
};

pub fn SerializerT(comptime GenericReader: type) type {
    return struct {
        const Self = @This();

        arena: std.heap.ArenaAllocator,

        pub fn init(allocator: std.mem.Allocator) !Self {
            return .{
                .arena = std.heap.ArenaAllocator.init(allocator),
            };
        }

        pub fn reset(self: *Self) void {
            self.arena.reset(.retain_capacity);
        }

        pub fn process(self: *Self, reader: GenericReader) SerializerError!types.ZType {
            const request_type: u8 = try reader.readByte();
            switch (request_type) {
                '+' => return try self.serializeSimpleString(reader),
                '$' => return try self.serializeString(reader),
                ',' => return try self.serializeFloat(reader),
                '*' => return try self.serializeArray(reader),
                '-' => return try self.serializeError(reader),
                '#' => return try self.serializeBool(reader),
                '_' => return try self.serializeNull(reader),
                '%' => return try self.serializeMap(reader),
                ':' => return try self.serializeInt(reader),
                '~' => return try self.serializeUnorderedSet(reader),
                '/' => return try self.serializeSet(reader),
                else => return error.Unprocessable,
            }
        }

        pub fn deinit(self: *Self) void {
            self.arena.deinit();
        }

        fn serializeSimpleString(self: *Self, reader: GenericReader) SerializerError!types.ZType {
            const bytes = try self.takeLineSlice(reader);
            if (bytes.len == 0) return error.Unprocessable;

            return .{ .sstr = bytes };
        }

        fn serializeString(self: *Self, reader: GenericReader) SerializerError!types.ZType {
            const bytes = try self.takeLineSlice(reader);

            const string_len = std.fmt.parseInt(usize, bytes, 10) catch {
                return error.Unprocessable;
            };

            if (string_len > MAX_BULK_LEN and MAX_BULK_LEN != 0) return error.PayloadExceeded;

            const string = try self.takeLineSlice(reader);
            if (string.len == 0) return error.Unprocessable;

            return .{ .str = string[0..string.len] };
        }

        fn serializeInt(self: *Self, reader: GenericReader) SerializerError!types.ZType {
            const bytes = try self.takeLineSlice(reader);
            if (bytes.len == 0) return error.Unprocessable;

            const int = std.fmt.parseInt(i64, bytes, 10) catch {
                return error.InvalidType;
            };

            return .{ .int = int };
        }

        fn serializeBool(self: *Self, reader: GenericReader) SerializerError!types.ZType {
            const bytes = try self.takeLineSlice(reader);

            if (bytes.len != 1) return error.Unprocessable;

            const value = bytes;
            if (std.mem.eql(u8, value, "t") or std.mem.eql(u8, value, "T")) {
                return .{ .bool = true };
            }
            if (std.mem.eql(u8, value, "f") or std.mem.eql(u8, value, "F")) {
                return .{ .bool = false };
            }

            return error.InvalidType;
        }

        fn serializeFloat(self: *Self, reader: GenericReader) SerializerError!types.ZType {
            const bytes = try self.takeLineSlice(reader);

            if (bytes.len == 0) return error.Unprocessable;

            const float = std.fmt.parseFloat(f64, bytes) catch {
                return error.InvalidType;
            };

            return .{ .float = float };
        }

        fn serializeArray(self: *Self, reader: GenericReader) SerializerError!types.ZType {
            const bytes = try self.takeLineSlice(reader);

            if (bytes.len == 0) return error.Unprocessable;

            const array_len = std.fmt.parseInt(usize, bytes, 10) catch {
                return error.InvalidLength;
            };

            var result = try std.array_list.Managed(types.ZType).initCapacity(
                self.arena.allocator(),
                array_len,
            );

            for (0..array_len) |_| {
                const item = try self.process(reader);
                try result.append(item);
            }
            return .{ .array = result };
        }

        fn serializeNull(self: *Self, reader: GenericReader) SerializerError!types.ZType {
            _ = self;
            reader.context.pos += 2; // we skip it, only one possible value
            return .{ .null = void{} };
        }

        // Only for client side, server should never receive an error
        fn serializeError(self: *Self, reader: GenericReader) SerializerError!types.ZType {
            const error_message = try self.takeLineSlice(reader);

            if (error_message.len < 1) return error.Unprocessable;

            return .{
                .err = .{
                    .message = error_message,
                },
            };
        }

        fn serializeMap(self: *Self, reader: GenericReader) SerializerError!types.ZType {
            const bytes = try self.takeLineSlice(reader);

            if (bytes.len == 0) return error.Unprocessable;

            const entries = std.fmt.parseInt(usize, bytes, 10) catch {
                return error.InvalidLength;
            };

            if (entries == 0) return error.Unprocessable;

            var result = std.StringHashMap(types.ZType).init(self.arena.allocator());

            for (0..entries) |_| {
                const key = try self.process(reader);

                const value = try self.process(reader);

                switch (std.meta.activeTag(key)) {
                    .str => try result.put(key.str, value),
                    .sstr => try result.put(key.sstr, value),
                    else => return error.InvalidKey,
                }
            }
            return .{ .map = result };
        }

        fn serializeSet(self: *Self, reader: GenericReader) SerializerError!types.ZType {
            const bytes = try self.takeLineSlice(reader);

            if (bytes.len == 0) return error.Unprocessable;

            const set_len = std.fmt.parseInt(usize, bytes, 10) catch {
                return error.InvalidLength;
            };

            var set = types.sets.Set(types.ZType).init(
                self.arena.allocator(),
            );

            for (0..set_len) |_| {
                const item = try self.process(reader);
                try set.insert(item);
            }
            return .{ .set = set };
        }

        fn serializeUnorderedSet(self: *Self, reader: GenericReader) SerializerError!types.ZType {
            const bytes = try self.takeLineSlice(reader);

            if (bytes.len == 0) return error.Unprocessable;

            const set_len = std.fmt.parseInt(usize, bytes, 10) catch {
                return error.InvalidLength;
            };

            var uset = types.sets.SetUnordered(types.ZType).init(
                self.arena.allocator(),
            );

            for (0..set_len) |_| {
                const item = try self.process(reader);
                try uset.insert(item);
            }
            return .{ .uset = uset };
        }

        fn takeLineSlice(self: *Self, reader: GenericReader) SerializerError![]const u8 {
            _ = self;
            const buf = reader.context.buffer;
            const start_pos = reader.context.pos;

            // Find the position of the newline character '\n' starting from current position
            const end_pos = std.mem.indexOfScalarPos(u8, buf, start_pos, '\n') orelse {
                // Return error if no newline is found
                // This would happen only when malformed input is received
                return error.Unprocessable;
            };
            if (end_pos < start_pos) return error.Unprocessable; // sanity check

            // Adjust the end position to skip a carriage return '\r' if it exists before '\n'
            var line_end = end_pos;
            if (line_end > start_pos and buf[line_end - 1] == '\r') {
                line_end -= 1;
            }

            // Take a slice of the line (without '\r\n' or '\n') from the buffer
            const line = buf[start_pos..line_end];

            // Move the position past the newline character for the next read
            reader.context.pos = line_end + 2;

            // Return the slice pointing to the current line (zero-copy)
            return line;
        }
    };
}
