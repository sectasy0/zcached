const std = @import("std");

pub const FixedBufferStream = struct {
    buffer: []u8,
    pos: usize = 0,

    pub const Reader = struct {
        context: *FixedBufferStream,

        pub fn readByte(self: Reader) error{EndOfStream}!u8 {
            if (self.context.pos >= self.context.buffer.len) return error.EndOfStream;
            const byte = self.context.buffer[self.context.pos];
            self.context.pos += 1;
            return byte;
        }

        pub fn read(self: Reader, destination: []u8) usize {
            const count = @min(destination.len, self.context.buffer.len - self.context.pos);
            @memcpy(destination[0..count], self.context.buffer[self.context.pos..][0..count]);
            self.context.pos += count;
            return count;
        }

        pub fn readUntilDelimiterAlloc(
            self: Reader,
            allocator: std.mem.Allocator,
            delimiter: u8,
            max_size: usize,
        ) ![]u8 {
            const remainder = self.context.buffer[self.context.pos..];
            const end = std.mem.indexOfScalar(u8, remainder, delimiter) orelse return error.EndOfStream;
            if (end > max_size) return error.StreamTooLong;
            const result = try allocator.dupe(u8, remainder[0..end]);
            self.context.pos += end + 1;
            return result;
        }
    };

    pub fn reader(self: *FixedBufferStream) Reader {
        return .{ .context = self };
    }

    pub fn writer(self: *FixedBufferStream) Writer {
        return .{ .context = self };
    }

    pub fn getWritten(self: *const FixedBufferStream) []const u8 {
        return self.buffer[0..self.pos];
    }

    pub const Writer = struct {
        context: *FixedBufferStream,

        pub fn any(self: Writer) Writer {
            return self;
        }

        pub fn writeAll(self: Writer, bytes: []const u8) error{WriteFailed}!void {
            if (bytes.len > self.context.buffer.len - self.context.pos) return error.WriteFailed;
            @memcpy(self.context.buffer[self.context.pos..][0..bytes.len], bytes);
            self.context.pos += bytes.len;
        }

        pub fn writeByte(self: Writer, byte: u8) error{WriteFailed}!void {
            try self.writeAll(&.{byte});
        }

        pub fn print(self: Writer, comptime format: []const u8, args: anytype) !void {
            const bytes = try std.fmt.allocPrint(std.heap.page_allocator, format, args);
            defer std.heap.page_allocator.free(bytes);
            try self.writeAll(bytes);
        }
    };
};

pub fn fixedBufferStream(buffer: []const u8) FixedBufferStream {
    return .{ .buffer = @constCast(buffer) };
}
