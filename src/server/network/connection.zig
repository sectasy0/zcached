const std = @import("std");

const Connection = @This();

buffer: []u8,
position: usize = 0,
stream: std.net.Stream,
address: std.net.Address,

allocator: *std.mem.Allocator,

pub fn deinit(self: *Connection) void {
    self.allocator.free(self.buffer);
}

pub fn fd(self: *Connection) std.posix.socket_t {
    return self.stream.handle;
}

/// resizes connection buffer to `nsize`
pub fn resize_buffer(self: *Connection, nsize: usize) !void {
    self.buffer = try self.allocator.realloc(
        self.buffer,
        nsize,
    );

    self.buffer = self.buffer.ptr[0..nsize];
}

pub fn close(self: *Connection) void {
    self.stream.close();
}
