const std = @import("std");
const assert = std.debug.assert;
const Address = @import("address.zig").Address;

// Local modules
const consts = @import("consts.zig");
const server = @import("stream_server.zig");
const Stream = @import("stream.zig").Stream;

const Self = @This();

/// Stream abstraction over the socket handle.
stream: Stream,
/// Remote address of the connected client.
address: Address,

/// Static-sized buffer for reading incoming stream data.
buffer: [consts.CLIENT_BUFFER]u8,
/// Accumulator for incoming data.
accumulator: std.array_list.Managed(u8),
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
        .buffer = undefined,
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
    assert(self.buffer.len != 0);

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
    const read_size = try self.stream.read(self.buffer[0..]);
    if (read_size == 0) return error.ConnectionClosed;

    if (self.accumulator.items.len > max_size or read_size > max_size - self.accumulator.items.len) {
        return error.MessageTooLarge;
    }

    try self.accumulator.appendSlice(self.buffer[0..read_size]);

    // The processor consumes complete frames before the next read.
    _ = std.mem.indexOfScalar(u8, self.buffer[0..read_size], consts.EXT_CHAR) orelse {
        return error.IncompleteMessage;
    };
}

pub fn writePending(self: *Self) !void {
    try self.stream.writeAll(self.tx_accumulator.items);
    self.tx_accumulator.clearRetainingCapacity();
}
