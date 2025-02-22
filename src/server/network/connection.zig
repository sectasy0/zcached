const std = @import("std");
const assert = std.debug.assert;

const server = @import("stream_server.zig");
const Stream = @import("stream.zig").Stream;

const Connection = @This();

buffer: []u8,
position: usize = 0,
stream: Stream,
address: std.net.Address,

allocator: std.mem.Allocator,

pub fn init(
    allocator: std.mem.Allocator,
    incoming: server.Connection,
    buffer_size: usize,
) !Connection {
    assert(buffer_size > 0);

    return .{
        .buffer = try allocator.alloc(u8, buffer_size),
        .position = 0,
        .stream = incoming.stream,
        .address = incoming.address,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Connection) void {
    assert(self.buffer.len != 0);

    self.allocator.free(self.buffer);
}

pub fn fd(self: *Connection) std.posix.socket_t {
    return self.stream.handle;
}

/// resizes connection buffer to `nsize`
pub fn resize_buffer(self: *Connection, nsize: usize) !void {
    assert(nsize > 0);
    assert(nsize > self.buffer.len);

    self.buffer = try self.allocator.realloc(
        self.buffer,
        nsize,
    );

    self.buffer = self.buffer.ptr[0..nsize];

    assert(self.buffer.len == nsize);
}

pub fn close(self: *Connection) void {
    assert(self.stream.handle > -1);

    self.stream.close();
}
