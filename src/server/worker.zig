const std = @import("std");
const Connection = @import("connection.zig");

const Worker = @This();

poll_fds: []std.os.pollfd = undefined,
states: std.AutoHashMap(std.os.socket_t, Connection),

connections: usize = 1, // 0 index is always listener fd.

allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, fds_size: usize) !Worker {
    return .{
        .poll_fds = try allocator.alloc(std.os.pollfd, fds_size),
        .allocator = allocator,
        .states = std.AutoHashMap(std.os.socket_t, Connection).init(allocator),
    };
}

pub fn deinit(self: *Worker) void {
    self.states.deinit();
    self.allocator.free(self.poll_fds);
}
