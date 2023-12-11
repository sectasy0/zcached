const std = @import("std");

const server = @import("server/listener.zig");
const storage = @import("storage.zig");

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();

    var mem_storage = storage.MemoryStorage.init(allocator);
    defer mem_storage.deinit();

    var thread_pool: std.Thread.Pool = undefined;
    thread_pool.init(.{ .allocator = allocator }) catch |err| {
        std.log.err("failed to initialize thread pool: {}", .{err});
        return;
    };
    defer thread_pool.deinit();

    const listen_addr = std.net.Address.parseIp("127.0.0.1", 7556) catch |err| {
        std.log.err("failed to parse address: {}", .{err});
        return;
    };
    var srv = server.ServerListener.init(
        &listen_addr,
        allocator,
        &thread_pool,
        &mem_storage,
    ) catch |err| {
        std.log.err("failed to initialize server: {}", .{err});
        return;
    };
    defer srv.deinit();

    std.log.info("starting zcached server on {}", .{listen_addr});

    srv.listen() catch |err| {
        std.log.err("failed to listen: {}", .{err});
        return;
    };
}
