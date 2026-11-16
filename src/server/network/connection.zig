const std = @import("std");
const assert = std.debug.assert;
const Address = @import("address.zig").Address;

// Local modules
const consts = @import("consts.zig");
const server = @import("stream_server.zig");
const Stream = @import("stream.zig").Stream;

const Self = @This();
const max_read_chunk: usize = 64 * 1024;

/// Stream abstraction over the socket handle.
stream: Stream,
/// Remote address of the connected client.
address: Address,

/// Accumulator for incoming data.
accumulator: std.array_list.Managed(u8),
receive_start: usize = 0,
read_chunk: usize = consts.CLIENT_BUFFER,
/// Accumulator for outgoing data.
tx_accumulator: std.array_list.Managed(u8),

// --- Lifecycle ---

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

pub fn deinit(self: *Self) void {
    self.accumulator.deinit();
    self.tx_accumulator.deinit();
}

pub fn out(self: *Self) OutWriter {
    return .{ .list = &self.tx_accumulator };
}

pub const OutWriter = struct {
    list: *std.array_list.Managed(u8),

    pub fn writeAll(self: OutWriter, bytes: []const u8) !void {
        try self.list.appendSlice(bytes);
    }

    pub fn writeByte(self: OutWriter, byte: u8) !void {
        try self.list.append(byte);
    }

    pub fn print(self: OutWriter, comptime format: []const u8, args: anytype) !void {
        try self.list.print(format, args);
    }
};

// --- I/O Operations ---

pub fn readPending(self: *Self, max_size: usize) !void {
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
    const read_size = try self.stream.read(read_buffer);
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

pub fn writePending(self: *Self) !void {
    try self.stream.writeAll(self.tx_accumulator.items);
    self.tx_accumulator.clearRetainingCapacity();
}
