const std = @import("std");

const server = @import("server/listener.zig");
const Config = @import("server/config.zig");
const MemoryStorage = @import("server/storage.zig");
const cli = @import("server/cli.zig");
const Logger = @import("server/logger.zig").Logger;
const log = @import("server/logger.zig");

const TracingAllocator = @import("server/tracing.zig").TracingAllocator;
const persistance = @import("server/persistance.zig");

const Employer = @import("server/employer.zig");

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    @setCold(true);

    log: {
        const file = std.fs.cwd().createFile(
            log.DEFAULT_PATH,
            .{ .truncate = false },
        ) catch |err| {
            std.log.err("# failed to open log file: {?}", .{err});
            break :log;
        };

        file.seekFromEnd(0) catch |err| {
            std.log.err("# unable to seek log file eof: {?}", .{err});
            break :log;
        };

        const debug_info = std.debug.getSelfDebugInfo() catch break :log;
        const addr = ret_addr orelse @returnAddress();

        std.debug.writeCurrentStackTrace(
            file.writer(),
            debug_info,
            .no_color,
            addr,
        ) catch break :log;

        file.writeAll("== END OF ERROR TRACE == \r\n") catch break :log;

        std.log.err("# server panicked, please check logs in ./log/zcached.log", .{});
    }

    std.builtin.default_panic(msg, error_return_trace, ret_addr);
}

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .safety = true,
        // .verbose_log = true,
        // .retain_metadata = true,
    }){};
    defer _ = gpa.deinit();
    var allocator = gpa.allocator();

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
            .Error,
            "# failed to init PersistanceHandler: {?}",
            .{err},
        );
        return;
    };
    defer persister.deinit();

    var tracing_allocator = TracingAllocator.init(allocator);
    var mem_storage = MemoryStorage.init(
        tracing_allocator.allocator(),
        config,
        &persister,
    );
    defer mem_storage.deinit();

    persister.load(&mem_storage) catch |err| {
        if (err != error.FileNotFound) {
            logger.log(
                .Warning,
                "# failed to restore data from latest .zcpf file: {?}",
                .{err},
            );
        }
    };

    const context = Employer.Context{
        .config = &config,
        .logger = &logger,
        .storage = &mem_storage,
    };

    run_supervisor(allocator, context);
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

fn run_supervisor(allocator: std.mem.Allocator, context: Employer.Context) void {
    context.logger.log(.Info, "# starting zcached server on {?}", .{
        context.config.address,
    });

    var employer = Employer.init(allocator, context) catch |err| {
        context.logger.log(.Error, "# failed to initialize server: {any}", .{err});
        return;
    };

    employer.supervise();
}
