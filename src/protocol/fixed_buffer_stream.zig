//! Reader and writer adapters that operate on a caller-provided fixed buffer.

const std = @import("std");

/// A bounded byte stream whose cursor is shared by its reader and writer views.
pub const FixedBufferStream = struct {
    /// Backing storage; reads and writes use this same mutable slice.
    buffer: []u8,
    /// Offset of the next byte to read or write.
    pos: usize = 0,

    /// Reads bytes from the stream's current cursor.
    pub const Reader = struct {
        /// Shared stream state, including the backing bytes and cursor.
        context: *FixedBufferStream,

        /// Reads one byte or reports that the cursor reached the buffer end.
        pub fn readByte(self: Reader) error{EndOfStream}!u8 {
            if (self.context.pos >= self.context.buffer.len) return error.EndOfStream;
            const byte = self.context.buffer[self.context.pos];
            self.context.pos += 1;
            return byte;
        }

        /// Copies as many remaining bytes as fit in `destination`.
        pub fn read(self: Reader, destination: []u8) usize {
            const count = @min(destination.len, self.context.buffer.len - self.context.pos);
            @memcpy(destination[0..count], self.context.buffer[self.context.pos..][0..count]);
            self.context.pos += count;
            return count;
        }

        /// Allocates bytes up to `delimiter`, enforcing `max_size`.
        /// Returns `EndOfStream` if the delimiter is absent and `StreamTooLong`
        /// if the delimited content exceeds the limit.
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

    /// Creates a reader sharing this stream's cursor.
    pub fn reader(self: *FixedBufferStream) Reader {
        return .{ .context = self };
    }

    /// Creates a writer sharing this stream's cursor.
    pub fn writer(self: *FixedBufferStream) Writer {
        return .{ .context = self };
    }

    /// Returns the prefix written so far; the slice borrows the backing buffer.
    pub fn getWritten(self: *const FixedBufferStream) []const u8 {
        return self.buffer[0..self.pos];
    }

    /// Writes bytes into the stream's remaining buffer capacity.
    pub const Writer = struct {
        /// Shared stream state, including the backing bytes and cursor.
        context: *FixedBufferStream,

        /// Returns this writer as the generic writer adapter expected by callers.
        pub fn any(self: Writer) Writer {
            return self;
        }

        /// Copies all bytes or fails without writing when capacity is insufficient.
        pub fn writeAll(self: Writer, bytes: []const u8) error{WriteFailed}!void {
            if (bytes.len > self.context.buffer.len - self.context.pos) return error.WriteFailed;
            @memcpy(self.context.buffer[self.context.pos..][0..bytes.len], bytes);
            self.context.pos += bytes.len;
        }

        /// Appends one byte, failing when the fixed buffer is full.
        pub fn writeByte(self: Writer, byte: u8) error{WriteFailed}!void {
            try self.writeAll(&.{byte});
        }

        /// Formats into a temporary allocation, then appends the result.
        pub fn print(self: Writer, comptime format: []const u8, args: anytype) !void {
            const bytes = try std.fmt.allocPrint(std.heap.page_allocator, format, args);
            defer std.heap.page_allocator.free(bytes);
            try self.writeAll(bytes);
        }
    };
};

/// Wraps an existing byte slice as a stream starting at offset zero.
/// The returned stream borrows the supplied storage; writes require mutable backing bytes.
pub fn fixedBufferStream(buffer: []const u8) FixedBufferStream {
    return .{ .buffer = @constCast(buffer) };
}
