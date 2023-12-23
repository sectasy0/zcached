const os = @import("std").os;
const std = @import("std");

const types = @import("types.zig");

pub fn SerializerT(comptime GenericReader: type) type {
    return struct {
        const Self = @This();

        const HandlerFunc = fn (self: *Self, reader: GenericReader) anyerror!types.AnyType;
        handlers: std.StringHashMap(*const HandlerFunc),
        arena: std.heap.ArenaAllocator,

        raw: std.ArrayList(u8),

        pub fn init(allocator: std.mem.Allocator) !Self {
            var handler = Self{
                .handlers = std.StringHashMap(*const HandlerFunc).init(allocator),
                .arena = std.heap.ArenaAllocator.init(allocator),
                .raw = std.ArrayList(u8).init(allocator),
            };

            try handler.handlers.put("+", serialize_sstring);
            try handler.handlers.put("$", serialize_string);
            try handler.handlers.put(",", serialize_float);
            try handler.handlers.put("*", serialize_array);
            try handler.handlers.put("-", serialize_error);
            try handler.handlers.put("#", serialize_bool);
            try handler.handlers.put("_", serialize_null);
            try handler.handlers.put("%", serialize_map);
            try handler.handlers.put(":", serialize_int);

            return handler;
        }

        pub fn process(self: *Self, reader: GenericReader) !types.AnyType {
            var request_type: [1]u8 = undefined;
            const size = try reader.readAtLeast(&request_type, 1);

            if (size == 0) return error.BadRequest;

            const handler_ref = self.handlers.get(&request_type) orelse return error.BadRequest;
            try self.raw.append(request_type[0]);
            return try handler_ref(self, reader);
        }

        pub fn deinit(self: *Self) void {
            self.handlers.deinit();
            self.arena.deinit();
            self.raw.deinit();
        }

        fn serialize_sstring(self: *Self, reader: GenericReader) !types.AnyType {
            const string = try self.read_line_alloc(reader) orelse return error.BadRequest;
            if (string.len == 0) return error.BadRequest;

            return .{ .str = @constCast(string[0 .. string.len - 1]) };
        }

        fn serialize_string(self: *Self, reader: GenericReader) !types.AnyType {
            const bytes = try self.read_line_alloc(reader) orelse return error.BadRequest;

            const string_len = std.fmt.parseInt(usize, bytes[0 .. bytes.len - 1], 10) catch {
                return error.BadRequest;
            };

            const string = try self.read_line_alloc(reader) orelse return error.BadRequest;
            if (string.len == 0) return error.BadRequest;
            // .len - 1 because we don't want to include the \n
            if (string_len != string.len - 1) return error.BadRequest;

            return .{ .str = @constCast(string[0 .. string.len - 1]) };
        }

        fn serialize_int(self: *Self, reader: GenericReader) !types.AnyType {
            const bytes = try self.read_line_alloc(reader) orelse return error.BadRequest;
            if (bytes.len == 0) return error.BadRequest;

            const int = std.fmt.parseInt(i64, bytes[0 .. bytes.len - 1], 10) catch {
                return error.NotInteger;
            };

            return .{ .int = int };
        }

        fn serialize_bool(self: *Self, reader: GenericReader) !types.AnyType {
            const bytes = try self.read_line_alloc(reader) orelse return error.BadRequest;

            // <bool> is either "t" or "f", with \n at the end is 2 bytes
            if (bytes.len != 2) return error.BadRequest;

            const value = bytes[0 .. bytes.len - 1];
            if (std.mem.eql(u8, value, "t") or std.mem.eql(u8, value, "T")) {
                return .{ .bool = true };
            }
            if (std.mem.eql(u8, value, "f") or std.mem.eql(u8, value, "F")) {
                return .{ .bool = false };
            }

            return error.NotBoolean;
        }

        fn serialize_float(self: *Self, reader: GenericReader) !types.AnyType {
            const bytes = try self.read_line_alloc(reader) orelse return error.BadRequest;

            if (bytes.len == 0) return error.BadRequest;

            const float = std.fmt.parseFloat(f64, bytes[0 .. bytes.len - 1]) catch {
                return error.NotFloat;
            };

            return .{ .float = float };
        }

        fn serialize_array(self: *Self, reader: GenericReader) !types.AnyType {
            const bytes = try self.read_line_alloc(reader) orelse return error.BadRequest;

            if (bytes.len == 0) return error.BadRequest;

            const array_len = std.fmt.parseInt(usize, bytes[0 .. bytes.len - 1], 10) catch {
                return error.InvalidArrayLength;
            };

            var result = std.ArrayList(types.AnyType).initCapacity(
                self.arena.allocator(),
                array_len,
            ) catch {
                return error.AllocatorError;
            };

            for (0..array_len) |_| {
                const item = try self.process(reader);
                try result.append(item);
            }
            return .{ .array = result };
        }

        fn serialize_null(self: *Self, reader: GenericReader) !types.AnyType {
            _ = reader;
            try self.raw.appendSlice("_\r\n");
            return .{ .null = void{} };
        }

        // Only for client side, server should never receive an error
        fn serialize_error(self: *Self, reader: GenericReader) !types.AnyType {
            const error_message = try self.read_line_alloc(reader) orelse return error.BadRequest;

            if (error_message.len < 1) return error.BadRequest;

            return .{ .err = .{
                .message = error_message[0 .. error_message.len - 1],
            } };
        }

        fn serialize_map(self: *Self, reader: GenericReader) !types.AnyType {
            const bytes = try self.read_line_alloc(reader) orelse return error.BadRequest;

            if (bytes.len == 0) return error.BadRequest;

            const entries = std.fmt.parseInt(usize, bytes[0 .. bytes.len - 1], 10) catch {
                return error.InvalidHashLength;
            };

            var result = std.StringHashMap(types.AnyType).init(self.arena.allocator());

            for (0..entries) |_| {
                const key = try self.process(reader);

                const active_tag = std.meta.activeTag(key);
                if (active_tag != .str and active_tag != .sstr) return error.InvalidHashKey;

                const value = try self.process(reader);
                try result.put(key.str, value);
            }
            return .{ .map = result };
        }

        fn read_line_alloc(self: *Self, reader: GenericReader) !?[]const u8 {
            const bytes: ?[]const u8 = reader.readUntilDelimiterAlloc(
                self.arena.allocator(),
                '\n',
                std.math.maxInt(usize),
            ) catch {
                return error.BadRequest;
            };

            if (bytes != null) {
                try self.raw.appendSlice(bytes.?);
                try self.raw.appendSlice("\n");
            }
            return bytes;
        }
    };
}

test "ProtocolHandler handle simple command" {
    var stream = std.io.fixedBufferStream("*3\r\n$3\r\nSET\r\n$9\r\nmycounter\r\n:42\r\n");

    var reader = stream.reader();

    const HandlerType = SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    var result = try handler.process(reader);
    var result_array = result.array.items;
    try std.testing.expectEqualStrings("SET", result_array[0].str);
    try std.testing.expectEqualStrings("mycounter", result_array[1].str);
    try std.testing.expectEqual(.{ .int = 42 }, result_array[2].int);
}

test "ProtocolHandler handle empty bufferr" {
    var stream = std.io.fixedBufferStream("");

    var reader = stream.reader();

    const HandlerType = SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    var result = handler.process(reader);
    try std.testing.expectEqual(result, error.BadRequest);
}

test "ProtocolHandler handle simple string" {
    var stream = std.io.fixedBufferStream("+OK\r\n");

    var reader = stream.reader();

    const HandlerType = SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    var result = try handler.process(reader);
    try std.testing.expectEqualStrings("OK", result.str);
}

test "ProtocolHandler handle integer" {
    var stream = std.io.fixedBufferStream(":42\r\n");

    var reader = stream.reader();

    const HandlerType = SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    var result = try handler.process(reader);
    try std.testing.expectEqual(.{ .int = 42 }, result.int);
}

test "ProtocolHandler handle integer without value" {
    var stream = std.io.fixedBufferStream(":\r\n");

    var reader = stream.reader();

    const HandlerType = SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    var result = handler.process(reader);
    try std.testing.expectEqual(result, error.NotInteger);
}

test "ProtocolHandler handle string" {
    var stream = std.io.fixedBufferStream("$9\r\nmycounter\r\n");

    var reader = stream.reader();

    const HandlerType = SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    var result = try handler.process(reader);
    try std.testing.expectEqualStrings("mycounter", result.str);
}

test "ProtocolHandler handle string invalid length" {
    var stream = std.io.fixedBufferStream("$2\r\nmycounter");

    var reader = stream.reader();

    const HandlerType = SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    var result = handler.process(reader);
    try std.testing.expectEqual(result, error.BadRequest);
}

test "ProtocolHandler handle string lenght passed but value not" {
    var stream = std.io.fixedBufferStream("$9\r\n");

    var reader = stream.reader();

    const HandlerType = SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    var result = handler.process(reader);
    try std.testing.expectEqual(result, error.BadRequest);
}

test "ProtocolHandler handle boolean f value" {
    // any non-zero or positive value is considered true
    var stream = std.io.fixedBufferStream("#f\r\n");

    var reader = stream.reader();

    const HandlerType = SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    var result = handler.process(reader);
    try std.testing.expectEqual(result, .{ .bool = false });
}

test "ProtocolHandler handle boolean t value" {
    var stream = std.io.fixedBufferStream("#t\r\n");

    var reader = stream.reader();

    const HandlerType = SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    var result = handler.process(reader);
    try std.testing.expectEqual(result, .{ .bool = true });
}

test "ProtocolHandler handle boolean invalid value" {
    var stream = std.io.fixedBufferStream("#a\r\n");

    var reader = stream.reader();

    const HandlerType = SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    var result = handler.process(reader);
    try std.testing.expectEqual(result, error.NotBoolean);
}

test "ProtocolHandler handle null" {
    var stream = std.io.fixedBufferStream("_\r\n");

    var reader = stream.reader();

    const HandlerType = SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    var result = handler.process(reader);
    try std.testing.expectEqual(result, .{ .null = void{} });
}

test "ProtocolHandler handle error" {
    var stream = std.io.fixedBufferStream("-unknown command 'foobar'\r\n");

    var reader = stream.reader();

    const HandlerType = SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    var result = try handler.process(reader);
    try std.testing.expectEqualStrings("unknown command 'foobar'", result.err.message);
}

test "serialize float" {
    var stream = std.io.fixedBufferStream(",3.14\r\n");

    var reader = stream.reader();

    const HandlerType = SerializerT(@TypeOf(reader));
    var handler = try HandlerType.init(std.testing.allocator);
    defer handler.deinit();

    var result = try handler.process(reader);
    try std.testing.expectEqual(.{ .float = 3.14 }, result.float);
}
