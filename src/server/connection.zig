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

pub fn fd(self: *Connection) std.os.socket_t {
    return self.stream.handle;
}

pub fn close(self: *Connection) void {
    self.stream.close();
}
