const Stream = @import("stream.zig");

const std = @import("std");

pub const Context = void;
pub const StreamContext = struct {
    ctx: ?*anyopaque, // Use anyopaque for compatibility with both secure and unsecure contexts
    deinit: *const fn (self: *StreamContext) void,
};

pub fn read(ctx_ptr: ?*anyopaque, buffer: []u8) Stream.ReadError!usize {
    if (buffer.len == 0 or ctx_ptr == null) return 0;

    const fd: *std.posix.socket_t = @alignCast(@ptrCast(ctx_ptr));

    return std.posix.read(fd.*, buffer);
}

pub fn write(ctx_ptr: ?*anyopaque, buffer: []const u8) Stream.WriteError!usize {
    if (buffer.len == 0 or ctx_ptr == null) return 0;

    const fd: *std.posix.socket_t = @alignCast(@ptrCast(ctx_ptr));

    return std.posix.write(fd.*, buffer);
}
