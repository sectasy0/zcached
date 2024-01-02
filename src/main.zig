const std = @import("std");

const server = @import("server/listener.zig");
const Config = @import("server/config.zig").Config;
const storage = @import("server/storage.zig");
const CLIParser = @import("server/cli_parser.zig").CLIParser;
const Logger = @import("server/logger.zig").Logger;
const log = @import("server/logger.zig");

const TracingAllocator = @import("server/tracing.zig").TracingAllocator;
const persistance = @import("server/persistance.zig");

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();

    const args = CLIParser.parse(allocator) catch {
        CLIParser.show_help() catch |err| {
            std.log.err("# failed to show help: {}", .{err});
            return;
        };
        return;
    };
    defer args.deinit();

    if (args.help) {
        CLIParser.show_help() catch |err| {
            std.log.err("# failed to show help: {}", .{err});
            return;
        };
        return;
    }

    if (args.version) {
        CLIParser.show_version() catch |err| {
            std.log.err("# failed to show version: {}", .{err});
            return;
        };
        return;
    }

    const logger = Logger.init(allocator, args.@"log-path") catch |err| {
        std.log.err("# failed to initialize logger: {}", .{err});
        return;
    };

    const config = Config.load(
        allocator,
        args.@"config-path",
        args.@"log-path",
    ) catch |err| {
        logger.log(log.LogLevel.Error, "# failed to load config: {?}", .{err});
        return;
    };
    defer config.deinit();

    var persister = persistance.PersistanceHandler.init(
        allocator,
        config,
        logger,
        null,
    ) catch |err| {
        logger.log(
            log.LogLevel.Error,
            "# failed to init PersistanceHandler: {?}",
            .{err},
        );
        return;
    };
    defer persister.deinit();

    var tracing_allocator = TracingAllocator.init(allocator);
    var mem_storage = storage.MemoryStorage.init(
        tracing_allocator.allocator(),
        config,
    );
    defer mem_storage.deinit();

    persister.load(&mem_storage) catch |err| {
        if (err != error.FileNotFound) {
            logger.log(
                log.LogLevel.Warning,
                "# failed to restore data from latest .zcpf file: {?}",
                .{err},
            );
        }
    };

    run_server(allocator, config, logger, &mem_storage);
}

fn run_server(
    allocator: std.mem.Allocator,
    config: Config,
    logger: log.Logger,
    mem_storage: *storage.MemoryStorage,
) void {
    var thread_pool: std.Thread.Pool = undefined;
    thread_pool.init(.{ .allocator = allocator, .n_jobs = config.threads }) catch |err| {
        logger.log(log.LogLevel.Error, "# failed to initialize thread pool: {?}", .{err});
        return;
    };
    defer thread_pool.deinit();

    logger.log(log.LogLevel.Info, "# starting zcached server on {?}", .{config.address});

    var srv = server.ServerListener.init(
        &config.address,
        allocator,
        &thread_pool,
        mem_storage,
        &config,
        &logger,
    ) catch |err| {
        logger.log(log.LogLevel.Error, "# failed to initialize server: {any}", .{err});
        return;
    };
    defer srv.deinit();

    srv.listen() catch |err| {
        logger.log(log.LogLevel.Error, "# failed to listen: {any}", .{err});
        return;
    };
}
