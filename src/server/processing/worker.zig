const std = @import("std");

// Networking
const Connection = @import("../network/connection.zig");

const Worker = @This();

poll_fds: []std.posix.pollfd = undefined,
states: std.AutoHashMap(std.posix.socket_t, Connection),

connections: usize = 1, // 0 index is always listener fd.

running: *std.atomic.Value(bool),

allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, fds_size: usize, running: *std.atomic.Value(bool)) !Worker {
    return .{
        .poll_fds = try allocator.alloc(std.posix.pollfd, fds_size),
        .allocator = allocator,
        .states = std.AutoHashMap(std.posix.socket_t, Connection).init(allocator),
        .running = running,
    };
}

pub fn deinit(self: *Worker) void {
    self.states.deinit();
    self.allocator.free(self.poll_fds);
}
