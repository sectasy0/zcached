const std = @import("std");
const builtin = @import("builtin");

// Core utilities
const Config = @import("server/config.zig");
const cli = @import("server/cli.zig");
const log = @import("server/logger.zig");

// Networking
const server = @import("server/network/listener.zig");

// Processing / application logic
const Employer = @import("server/processing/employer.zig");

// Storage / memory
const Memory = @import("server/storage/memory.zig");
const persistance = @import("server/storage/persistance.zig");

// Tracing
const TracingAllocator = @import("server/tracing.zig");

pub const panic = std.debug.FullPanic(panicHandler);

var quantum_flow: std.atomic.Value(bool) = .init(true);

fn handleSig(sig: c_int) callconv(.C) void {
    _ = sig; // unused, but required by the signal handler signature
    // we want to stop the server gracefully, and also flush any pending logs
    quantum_flow.store(false, .seq_cst);
}

fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);

    _ = first_trace_addr; // unused, but required by the panic handler signature
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

        file.writeAll("== PANIC ==\r\n") catch break :log;
        file.writeAll(msg) catch break :log;

        const debug_info = std.debug.getSelfDebugInfo() catch break :log;
        const addr = @returnAddress();

        std.debug.writeCurrentStackTrace(
            file.writer(),
            debug_info,
            .no_color,
            addr,
        ) catch break :log;

        file.writeAll("== END OF ERROR TRACE == \r\n") catch break :log;

        std.log.err("# server panicked, please check logs in ./log/zcached.log", .{});
    }

    std.process.exit(1);
}

pub fn main() void {
    if (builtin.os.tag == .windows) @compileError("windows not supported");

    var gpa = std.heap.GeneralPurposeAllocator(.{
        .safety = true,
        // .verbose_log = true,
        // .retain_metadata = true,
    }){};
    defer _ = gpa.deinit();

    var thread_safe_allocator: std.heap.ThreadSafeAllocator = .{
        .child_allocator = gpa.allocator(),
    };
    const allocator = thread_safe_allocator.allocator();

    const result = cli.Parser.parse(allocator) catch {
        cli.Parser.showHelp() catch |err| {
            std.log.err("# failed to show help: {}", .{err});
            return;
        };
        return;
    };
    defer result.parser.deinit();

    handleArguments(result.args) orelse return;

    var logger = log.Logger.init(
        allocator,
        result.args.@"log-path",
        result.args.sout,
    ) catch |err| {
        std.log.err("# failed to initialize logger: {}", .{err});
        return;
    };
    defer logger.deinit();

    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = handleSig },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };

    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    std.posix.sigaction(std.posix.SIG.INT, &act, null);

    var config = Config.load(
        allocator,
        result.args.@"config-path",
        result.args.@"log-path",
    ) catch |err| {
        logger.log(log.LogLevel.Error, "# failed to load config: {?}", .{err});
        return;
    };
    defer config.deinit();

    var persister = persistance.Handler.init(
        allocator,
        config,
        logger,
        null,
    ) catch |err| {
        logger.log(
            .Error,
            "# failed to init persistance.Handler: {?}",
            .{err},
        );
        return;
    };
    defer persister.deinit();

    // allocator for database inner database data purposes.
    // we don't need to wrap it in a thread-safe allocator because Memory struct is secured by mutex
    var dbgpa = std.heap.GeneralPurposeAllocator(.{
        .safety = true,
        // .verbose_log = true,
        // .retain_metadata = true,
    }){};
    defer _ = dbgpa.deinit();

    var tracing = TracingAllocator.init(dbgpa.allocator());
    var memory = Memory.init(
        tracing.allocator(),
        config,
        &persister,
    );
    defer memory.deinit();

    persister.load(&memory) catch |err| {
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
        .resources = .{
            .memory = &memory,
            .logger = &logger,
        },
        .quantum_flow = &quantum_flow,
    };

    runSupervisor(allocator, context);
}

// null indicates that function should return from main
fn handleArguments(args: cli.Args) ?void {
    if (args.help) {
        cli.Parser.showHelp() catch |err| {
            std.log.err("# failed to show help: {}", .{err});
            return null;
        };
        return null;
    }

    if (args.version) {
        cli.Parser.showVersion() catch |err| {
            std.log.err("# failed to show version: {}", .{err});
            return null;
        };
        return null;
    }

    if (args.daemon) {
        if (args.pid == null) {
            std.log.err("# missing -pid file path", .{});
            return null;
        }
        const daemon = @import("server/daemon.zig");
        daemon.daemonize(args.pid.?);
        return void{};
    }
}

fn runSupervisor(allocator: std.mem.Allocator, context: Employer.Context) void {
    context.resources.logger.log(.Info, "# starting zcached server on tcp://{?} | Workers {}", .{
        context.config.address,
        context.config.workers,
    });

    var employer = Employer.init(allocator, context) catch |err| {
        context.resources.logger.log(.Error, "# failed to initialize server: {any}", .{err});
        return;
    };
    defer employer.deinit();

    employer.supervise();
}
