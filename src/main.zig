const std = @import("std");

const server = @import("server/listener.zig");
const Config = @import("server/config.zig").Config;
const storage = @import("server/storage.zig");
const cli = @import("server/cli.zig");
const Logger = @import("server/logger.zig").Logger;
const log = @import("server/logger.zig");

const TracingAllocator = @import("server/tracing.zig").TracingAllocator;
const persistance = @import("server/persistance.zig");

pub const io_mode = .evented;

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .safety = true,
        .verbose_log = true,
        .retain_metadata = true,
    }){};
    var lalloc = std.heap.loggingAllocator(gpa.allocator());
    var allocator = lalloc.allocator();

    const result = cli.Parser.parse(allocator) catch {
        cli.Parser.show_help() catch |err| {
            std.log.err("# failed to show help: {}", .{err});
            return;
        };
        return;
    };
    defer result.parser.deinit();

    handle_arguments(result.args) orelse return;

    const logger = Logger.init(allocator, result.args.@"log-path") catch |err| {
        std.log.err("# failed to initialize logger: {}", .{err});
        return;
    };

    const config = Config.load(
        allocator,
        result.args.@"config-path",
        result.args.@"log-path",
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
        &persister,
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

    run_server(.{
        .allocator = allocator,
        .config = &config,
        .logger = &logger,
        .storage = &mem_storage,
    });
}

// null indicates that function should return from main
fn handle_arguments(args: cli.Args) ?void {
    if (args.help) {
        cli.Parser.show_help() catch |err| {
            std.log.err("# failed to show help: {}", .{err});
            return null;
        };
        return null;
    }

    if (args.version) {
        cli.Parser.show_version() catch |err| {
            std.log.err("# failed to show version: {}", .{err});
            return null;
        };
        return null;
    }
}

const RunServerOptions = struct {
    allocator: std.mem.Allocator,
    config: *const Config,
    logger: *const Logger,
    storage: *storage.MemoryStorage,
};
fn run_server(options: RunServerOptions) void {
    var thread_pool: std.Thread.Pool = undefined;
    thread_pool.init(.{
        .allocator = options.allocator,
        .n_jobs = options.config.threads,
    }) catch |err| {
        options.logger.log(log.LogLevel.Error, "# failed to initialize thread pool: {?}", .{err});
        return;
    };
    defer thread_pool.deinit();

    options.logger.log(log.LogLevel.Info, "# starting zcached server on {?}", .{
        options.config.address,
    });

    var srv = server.ServerListener.init(
        &options.config.address,
        options.allocator,
        &thread_pool,
        options.storage,
        options.config,
        options.logger,
    ) catch |err| {
        options.logger.log(log.LogLevel.Error, "# failed to initialize server: {any}", .{err});
        return;
    };
    defer srv.deinit();

    srv.listen() catch |err| {
        options.logger.log(log.LogLevel.Error, "# failed to listen: {any}", .{err});
        return;
    };
}
