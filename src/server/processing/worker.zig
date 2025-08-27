const std = @import("std");

// Networking
const Connection = @import("../network/connection.zig");

const Worker = @This();

poll_fds: []std.posix.pollfd = undefined,
states: std.AutoHashMap(std.posix.socket_t, Connection),

connections: usize = 1, // 0 index is always listener fd.

allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, fds_size: usize) !Worker {
    return .{
        .poll_fds = try allocator.alloc(std.posix.pollfd, fds_size),
        .allocator = allocator,
        .states = std.AutoHashMap(std.posix.socket_t, Connection).init(allocator),
    };
}

pub fn deinit(self: *Worker) void {
    while (self.states.count() > 0) {
        var it = self.states.iterator();
        const entry = it.next() orelse break;
        const fd = entry.key_ptr.*;
        var conn = entry.value_ptr.*;
        if (!conn.isClosed()) conn.close();
        conn.deinit();

        // we ignore the result, because we are removing entries until the map is empty
        _ = self.states.remove(fd);
    }

    // additionally zero out poll_fds and connections
    self.connections = 0;
    self.states.deinit();
    self.allocator.free(self.poll_fds);
}
