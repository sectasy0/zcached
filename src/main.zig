const std = @import("std");

const server = @import("server/listener.zig");
const Config = @import("server/config.zig").Config;
const storage = @import("server/storage.zig");
const CLIParser = @import("server/cli_parser.zig").CLIParser;

const TracingAllocator = @import("server/tracing.zig").TracingAllocator;

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();

    const args = CLIParser.parse(allocator) catch |err| {
        std.log.err("failed to parse CLI arguments: {}", .{err});
        return;
    };
    defer args.deinit();

    const config = Config.load(allocator, args.@"config-path") catch |err| {
        std.log.err("failed to load config: {}", .{err});
        return;
    };
    defer config.deinit();

    var tracing_allocator = TracingAllocator.init(allocator);
    var mem_storage = storage.MemoryStorage.init(tracing_allocator.allocator(), config);
    defer mem_storage.deinit();

    var thread_pool: std.Thread.Pool = undefined;
    thread_pool.init(.{ .allocator = allocator }) catch |err| {
        std.log.err("failed to initialize thread pool: {}", .{err});
        return;
    };
    defer thread_pool.deinit();

    var srv = server.ServerListener.init(
        &config.address,
        allocator,
        &thread_pool,
        &mem_storage,
        &config,
    ) catch |err| {
        std.log.err("failed to initialize server: {}", .{err});
        return;
    };
    defer srv.deinit();

    std.log.info("starting zcached server on {}", .{config.address});

    srv.listen() catch |err| {
        std.log.err("failed to listen: {}", .{err});
        return;
    };
}
