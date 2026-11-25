//! Parses protocol wire data into recursively owned typed values.

const std = @import("std");
const os = std.os;

const types = @import("types.zig");
const Config = @import("../server/config.zig");

/// Optional upper bound for bulk-string payloads; zero disables the limit.
pub var MAX_BULK_LEN: usize = 0;

/// Errors raised while recognizing wire values or allocating parsed data.
const SerializerError = error{
    /// The input contains an unsupported marker or malformed value.
    Unprocessable,
    /// A parsed scalar does not match its required representation.
    InvalidType,
    /// The reader has no byte available for the next protocol marker.
    EndOfStream,
    /// A collection length cannot be parsed as a nonnegative integer.
    InvalidLength,
    /// A map key is not a string or simple string.
    InvalidKey,
    /// An allocation failed while constructing a parsed value.
    OutOfMemory,
    /// The configured allocator could not satisfy a request.
    AllocatorError,
    /// A bulk string exceeds the configured payload limit.
    PayloadExceeded,
};

/// Creates a parser specialized for `GenericReader`.
/// Parsed allocations live in an arena and are invalidated by reset or deinit.
pub fn SerializerT(comptime GenericReader: type) type {
    return struct {
        const Self = @This();

        /// Owns nested values and slices produced while parsing.
        arena: std.heap.ArenaAllocator,

        /// Initializes the arena from a caller-owned allocator.
        pub fn init(allocator: std.mem.Allocator) !Self {
            return .{
                .arena = std.heap.ArenaAllocator.init(allocator),
            };
        }

        /// Frees parsed values while retaining arena capacity for reuse.
        pub fn reset(self: *Self) void {
            _ = self.arena.reset(.retain_capacity);
        }

        /// Reads and parses one value beginning at the reader's current position.
        /// Malformed input and allocation failures are returned as `SerializerError`.
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

        /// Releases the arena and all parsed values it owns.
        pub fn deinit(self: *Self) void {
            self.arena.deinit();
        }

        /// Reads a nonempty line as a protocol simple string without copying it.
        fn serializeSimpleString(self: *Self, reader: GenericReader) SerializerError!types.ZType {
            const bytes = try self.takeLineSlice(reader);
            if (bytes.len == 0) return error.Unprocessable;

            return .{ .sstr = bytes };
        }

        /// Parses a bulk-string length and returns a borrowed slice into the reader buffer.
        fn serializeString(self: *Self, reader: GenericReader) SerializerError!types.ZType {
            const bytes = try self.takeLineSlice(reader);

            const string_len = std.fmt.parseInt(usize, bytes, 10) catch {
                return error.Unprocessable;
            };

            if (string_len > MAX_BULK_LEN and MAX_BULK_LEN != 0) return error.PayloadExceeded;

            const buffer = reader.context.buffer;
            const start = reader.context.pos;
            const end = std.math.add(usize, start, string_len) catch return error.Unprocessable;
            const terminator_end = std.math.add(usize, end, 2) catch return error.Unprocessable;
            if (terminator_end > buffer.len or
                buffer[end] != '\r' or
                buffer[end + 1] != '\n')
            {
                return error.Unprocessable;
            }

            reader.context.pos = terminator_end;
            return .{ .str = buffer[start..end] };
        }

        /// Parses a signed decimal integer from one protocol line.
        fn serializeInt(self: *Self, reader: GenericReader) SerializerError!types.ZType {
            const bytes = try self.takeLineSlice(reader);
            if (bytes.len == 0) return error.Unprocessable;

            const int = std.fmt.parseInt(i64, bytes, 10) catch {
                return error.InvalidType;
            };

            return .{ .int = int };
        }

        /// Parses the one-byte true or false spelling accepted by the protocol.
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

        /// Parses a floating-point value from one protocol line.
        fn serializeFloat(self: *Self, reader: GenericReader) SerializerError!types.ZType {
            const bytes = try self.takeLineSlice(reader);

            if (bytes.len == 0) return error.Unprocessable;

            const float = std.fmt.parseFloat(f64, bytes) catch {
                return error.InvalidType;
            };

            return .{ .float = float };
        }

        /// Parses a count followed by that many recursively encoded values.
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

        /// Consumes the null marker's remaining CRLF bytes and returns null.
        fn serializeNull(self: *Self, reader: GenericReader) SerializerError!types.ZType {
            _ = self;
            const buffer = reader.context.buffer;
            const pos = reader.context.pos;
            if (pos + 2 > buffer.len or
                buffer[pos] != '\r' or
                buffer[pos + 1] != '\n')
            {
                return error.Unprocessable;
            }
            reader.context.pos += 2;
            return .{ .null = {} };
        }

        // Only for client side, server should never receive an error
        /// Parses a client-side error line into a compatibility value.
        fn serializeError(self: *Self, reader: GenericReader) SerializerError!types.ZType {
            const error_message = try self.takeLineSlice(reader);

            if (error_message.len < 1) return error.Unprocessable;

            return .{
                .err = .{
                    .message = error_message,
                },
            };
        }

        /// Parses string-keyed map entries, rejecting non-string keys.
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

        /// Parses a count of values into an insertion-ordered set.
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

        /// Parses a count of values into an unordered set.
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

        /// Returns the next line as a zero-copy slice and advances the reader.
        /// Missing newlines are reported as malformed input.
        fn takeLineSlice(self: *Self, reader: GenericReader) SerializerError![]const u8 {
            _ = self;
            const buf = reader.context.buffer;
            const start_pos = reader.context.pos;

            const end_pos = std.mem.indexOfScalarPos(u8, buf, start_pos, '\n') orelse {
                return error.Unprocessable;
            };
            if (end_pos == start_pos or buf[end_pos - 1] != '\r') return error.Unprocessable;
            reader.context.pos = end_pos + 1;
            return buf[start_pos .. end_pos - 1];
        }
    };
}
