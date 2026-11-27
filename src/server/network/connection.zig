//! Buffered request and response I/O for one accepted client connection.
const std = @import("std");
const assert = std.debug.assert;
const Address = @import("address.zig").Address;

// Local modules
const consts = @import("consts.zig");
const server = @import("stream_server.zig");
const Stream = @import("stream.zig").Stream;

/// Current connection type, used by methods returning or mutating this value.
const Self = @This();
/// Upper bound for the adaptive size of a single socket read.
const max_read_chunk: usize = 64 * 1024;
/// Stream abstraction over the socket handle.
stream: Stream,
/// Remote address of the connected client.
address: Address,

/// Accumulator holding received bytes until the request processor consumes them.
accumulator: std.array_list.Managed(u8),
/// Index of the first unread byte; earlier bytes may remain until compaction is needed.
receive_start: usize = 0,
/// Current read size, increased after full reads up to `max_read_chunk`.
read_chunk: usize = consts.CLIENT_BUFFER,
/// Bytes returned by the most recent socket read, including a rejected over-limit read.
last_read_bytes: usize = 0,
/// Accumulator containing response bytes awaiting transmission.
tx_accumulator: std.array_list.Managed(u8),

// --- Lifecycle ---

/// Initializes per-connection buffers; the accepted stream remains owned by the caller.
pub fn init(
    allocator: std.mem.Allocator,
    incoming: server.Connection,
) !Self {
    assert(consts.CLIENT_BUFFER > 0);

    var accumulator = try std.array_list.Managed(u8).initCapacity(allocator, consts.CLIENT_BUFFER);
    errdefer accumulator.deinit();

    return .{
        .stream = incoming.stream,
        .address = incoming.address,
        .accumulator = accumulator,
        .tx_accumulator = try .initCapacity(
            allocator,
            consts.CLIENT_BUFFER,
        ),
    };
}

/// Releases the request and response buffers; does not close the transport.
pub fn deinit(self: *Self) void {
    self.accumulator.deinit();
    self.tx_accumulator.deinit();
}

/// Returns a writer that appends response bytes to this connection's output buffer.
pub fn out(self: *Self) OutWriter {
    return .{ .list = &self.tx_accumulator };
}

pub const OutWriter = struct {
    /// Destination buffer, valid only while the owning connection remains alive.
    list: *std.array_list.Managed(u8),

    /// Appends all bytes, returning allocation failure if the buffer cannot grow.
    pub fn writeAll(self: OutWriter, bytes: []const u8) !void {
        try self.list.appendSlice(bytes);
    }

    /// Appends one byte to the pending response.
    pub fn writeByte(self: OutWriter, byte: u8) !void {
        try self.list.append(byte);
    }

    /// Formats and appends response data using Zig's formatting rules.
    pub fn print(self: OutWriter, comptime format: []const u8, args: anytype) !void {
        try self.list.print(format, args);
    }
};

// --- I/O Operations ---

/// Reads more request bytes, enforcing the limit on unread data and requiring a frame terminator.
pub fn readPending(self: *Self, max_size: usize) !void {
    return self.readPendingTimed(max_size, .none);
}

pub fn readPendingTimed(self: *Self, max_size: usize, timeout: std.Io.Timeout) !void {
    self.last_read_bytes = 0;
    const pending_len = self.accumulator.items.len - self.receive_start;
    if (pending_len > max_size) return error.MessageTooLarge;

    const remaining = max_size - pending_len;
    const read_capacity = if (remaining < self.read_chunk)
        remaining + 1
    else
        self.read_chunk;

    if (self.receive_start > 0 and self.accumulator.capacity - self.accumulator.items.len < read_capacity) {
        std.mem.copyForwards(u8, self.accumulator.items, self.accumulator.items[self.receive_start..]);
        self.accumulator.shrinkRetainingCapacity(pending_len);
        self.receive_start = 0;
    }

    try self.accumulator.ensureUnusedCapacity(read_capacity);
    const old_len = self.accumulator.items.len;
    const read_buffer = self.accumulator.items.ptr[old_len .. old_len + read_capacity];
    const read_size = try self.stream.readTimed(read_buffer, timeout);
    self.last_read_bytes = read_size;
    if (read_size == 0) return error.ConnectionClosed;

    if (read_size > remaining) return error.MessageTooLarge;
    self.accumulator.items.len += read_size;
    if (read_size == self.read_chunk) {
        self.read_chunk = @min(self.read_chunk * 2, max_read_chunk);
    }

    // The processor consumes complete frames before the next read.
    _ = std.mem.indexOfScalar(u8, read_buffer[0..read_size], consts.EXT_CHAR) orelse {
        return error.IncompleteMessage;
    };
}

/// Reports whether at least one complete request frame remains unread.
pub fn hasPendingFrame(self: *Self) bool {
    return std.mem.indexOfScalarPos(
        u8,
        self.accumulator.items,
        self.receive_start,
        consts.EXT_CHAR,
    ) != null;
}

/// Sends the full buffered response and retains buffer capacity for later writes.
pub fn writePending(self: *Self) !void {
    try self.stream.writeAll(self.tx_accumulator.items);
    self.tx_accumulator.clearRetainingCapacity();
}
