const std = @import("std");
const assert = std.debug.assert;

// Local modules
const consts = @import("consts.zig");
const server = @import("stream_server.zig");
const Stream = @import("stream.zig").Stream;

const Self = @This();

/// Unique identifier for the connection, typically the index in the worker's connection array.
id: usize = 0,
/// File descriptor for polling I/O readiness.
pollfd: *std.posix.pollfd,

/// Static-sized buffer for reading incoming stream data.
buffer: [consts.CLIENT_BUFFER]u8,
/// Stream abstraction over the socket handle.
stream: Stream,
/// Remote address of the connected client.
address: std.net.Address,

/// Accumulator for incoming data.
accumulator: std.ArrayList(u8),
/// Accumulator for outgoing data.
tx_accumulator: std.ArrayList(u8),

/// Allocator for dynamic memory use.
allocator: std.mem.Allocator,

// --- Lifecycle ---

pub fn init(
    allocator: std.mem.Allocator,
    incoming: server.Connection,
    pollfd: *std.posix.pollfd,
    id: usize,
) !Self {
    assert(consts.CLIENT_BUFFER > 0);

    return Self{
        .id = id,
        .buffer = undefined,
        .pollfd = pollfd,
        .stream = incoming.stream,
        .address = incoming.address,
        .accumulator = try std.ArrayList(u8).initCapacity(
            allocator,
            consts.CLIENT_BUFFER,
        ),
        .tx_accumulator = try std.ArrayList(u8).initCapacity(
            allocator,
            consts.CLIENT_BUFFER,
        ),
        .allocator = allocator,
    };
}

pub fn deinit(self: *Self) void {
    assert(self.buffer.len != 0);
    self.accumulator.deinit();
    self.tx_accumulator.deinit();
}

pub fn close(self: *Self) void {
    assert(self.stream.handle > -1);
    self.stream.close();
}

// --- Accessors ---

pub fn fd(self: *Self) std.posix.socket_t {
    return self.stream.handle;
}

pub fn isClosed(self: *Self) bool {
    return self.stream.handle < 0;
}

pub fn out(self: *Self) @TypeOf(self.tx_accumulator).Writer {
    return self.tx_accumulator.writer();
}

// --- I/O Operations ---

pub fn readPending(self: *Self, max_size: usize) !void {
    const read_size = try self.stream.read(self.buffer[0..]);
    if (read_size == 0) return error.ConnectionClosed;

    if (self.accumulator.items.len > max_size) {
        // Buffer overflow, return an error
        self.tx_accumulator.clearRetainingCapacity();
        return error.MessageTooLarge;
    }

    try self.accumulator.appendSlice(self.buffer[0..read_size]);

    const acc_slice = self.accumulator.items[0..];
    _ = std.mem.indexOfScalar(u8, acc_slice, consts.EXT_CHAR) orelse {
        return error.IncompleteMessage;
    };
}

pub fn writePending(self: *Self) !void {
    const write_size = self.tx_accumulator.items.len;
    if (write_size == 0) {
        self.clearWritable();
        return;
    }

    // Add the end character to the outgoing data
    self.tx_accumulator.append(consts.EXT_CHAR) catch |err| {
        return err;
    };
    _ = try self.stream.writeAll(self.tx_accumulator.items);

    self.clearWritable();
    self.tx_accumulator.clearRetainingCapacity();
}

// --- Polling Helpers ---

pub fn signalWritable(self: *Self) void {
    self.pollfd.*.events |= std.posix.POLL.OUT;
}

pub fn clearWritable(self: *Self) void {
    self.pollfd.*.events &= ~@as(i16, std.posix.POLL.OUT);
}
