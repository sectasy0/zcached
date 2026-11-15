const std = @import("std");
const builtin = @import("builtin");
const fs = @import("fs");
const runtime_io = @import("runtime_io");

// Core utilities
const Config = @import("server/config.zig");
const cli = @import("server/cli.zig");
const log = @import("server/logger.zig");

// Networking
const server = @import("server/network/listener.zig");

// Processing / application logic
const Employer = @import("server/processing/employer.zig");
const Agent = @import("server/processing/agent.zig");

// Storage / memory
const Memory = @import("server/storage/memory.zig");
const persistance = @import("server/storage/persistance.zig");
const AOF = @import("server/storage/aof.zig");

// Tracing
const TracingAllocator = @import("server/tracing.zig");

pub const panic = std.debug.FullPanic(panicHandler);

var running: std.atomic.Value(bool) = .init(true);

fn appendAOFCommand(ptr: *anyopaque, command: []const @import("protocol/types.zig").ZType) anyerror!void {
    const aof: *AOF = @ptrCast(@alignCast(ptr));
    try aof.appendCommand(command);
}

fn handleSig(sig: std.posix.SIG) callconv(.c) void {
    _ = sig; // unused, but required by the signal handler signature
    // we want to stop the server gracefully, and also flush any pending logs
    running.store(false, .seq_cst);
}

fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);

    _ = first_trace_addr; // unused, but required by the panic handler signature
    log: {
        const io = runtime_io.get();
        const file = fs.cwd().createFile(
            log.DEFAULT_PATH,
            .{ .truncate = false },
        ) catch |err| {
            std.log.err("# failed to open log file: {any}", .{err});
            break :log;
        };
        defer file.close();

        file.seekFromEnd(0) catch |err| {
            std.log.err("# unable to seek log file eof: {any}", .{err});
            break :log;
        };

        file.writeAll("== PANIC ==\r\n") catch break :log;
        file.writeAll(msg) catch break :log;

        const addr = @returnAddress();

        var buffer: [4096]u8 = undefined;
        var writer = file.inner.writerStreaming(io, &buffer).interface;
        std.debug.writeCurrentStackTrace(
            .{ .first_address = addr },
            .{ .writer = &writer, .mode = .no_color },
        ) catch break :log;

        file.writeAll("== END OF ERROR TRACE == \r\n") catch break :log;

        std.log.err("# server panicked, please check logs in ./log/zcached.log", .{});
    }

    std.process.exit(1);
}

pub fn main(init: std.process.Init) void {
    if (builtin.os.tag == .windows) @compileError("windows not supported");

    var gpa: std.heap.DebugAllocator(.{
        .safety = true,
        // .verbose_log = true,
        // .retain_metadata = true,
    }) = .init;
    defer {
        if (gpa.deinit() == .leak) std.process.exit(255);
    }

    const allocator = gpa.allocator();

    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    runtime_io.runtime = threaded_io.io();

    const result = cli.Parser.parse(allocator, init.minimal.args) catch {
        cli.Parser.showHelp() catch |err| {
            std.log.err("# failed to show help: {any}", .{err});
            return;
        };
        return;
    };
    defer result.parser.deinit();

    handleArguments(result.args) orelse return;

    // Background worker
    var agent: Agent = try .init(allocator, &running);
    agent.kickoff() catch |err| {
        std.log.err("# failed to initialize background agent: {any}", .{err});
    };

    var logger = log.Logger.init(
        allocator,
        &agent,
        result.args.@"log-path",
        result.args.sout,
    ) catch |err| {
        std.log.err("# failed to initialize logger: {any}", .{err});
        return;
    };

    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = handleSig },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };

    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    std.posix.sigaction(std.posix.SIG.INT, &act, null);

    var config = Config.load(
        allocator,
        result.args.@"config-path",
        result.args.@"log-path",
    ) catch |err| {
        logger.err("# failed to load config: {any}", .{err});
        return;
    };

    var persister = persistance.Handler.init(
        allocator,
        config,
        logger,
        null,
    ) catch |err| {
        logger.err("# failed to init persistance.Handler: {any}", .{err});
        return;
    };

    // allocator for database inner database data purposes.
    // we don't need to wrap it in a thread-safe allocator because Memory struct is secured by mutex
    var dbgpa: std.heap.DebugAllocator(.{
        .safety = true,
        // .verbose_log = true,
        // .retain_metadata = true,
    }) = .init;
    defer _ = dbgpa.deinit();

    var tracing = TracingAllocator.init(dbgpa.allocator());
    var memory = Memory.init(
        tracing.allocator(),
        config,
        &persister,
    );
    defer {
        memory.deinit();
        if (dbgpa.detectLeaks() != 0) std.process.exit(255);
    }

    persister.load(&memory) catch |err| {
        if (err != error.FileNotFound) {
            logger.warn("# failed to restore data from latest .zcpf file: {any}", .{err});
        }
    };

    var context = Employer.Context{
        .config = &config,
        .resources = .{
            .memory = &memory,
            .aof = null,
            .logger = &logger,
            .agent = &agent,
        },
        .running = &running,
    };

    var aof = AOF.init(allocator, context) catch |err| {
        logger.err("# failed to initialize AOF: {any}", .{err});
        return;
    };
    context.resources.aof = .{
        .ptr = &aof,
        .append_command = appendAOFCommand,
    };

    aof.replay() catch |err| {
        logger.warn("# failed to replay AOF file: {any}", .{err});
    };

    aof.start() catch |err| {
        logger.err("# failed to start AOF flush thread: {any}", .{err});
        aof.deinit();
        return;
    };

    runSupervisor(allocator, context);

    aof.deinit();
    persister.deinit();
    logger.deinit();
    config.deinit();
    agent.deinit();
}

// null indicates that function should return from main
fn handleArguments(args: cli.Args) ?void {
    if (args.help) {
        cli.Parser.showHelp() catch |err| {
            std.log.err("# failed to show help: {any}", .{err});
            return null;
        };
        return null;
    }

    if (args.version) {
        cli.Parser.showVersion() catch |err| {
            std.log.err("# failed to show version: {any}", .{err});
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
    context.resources.logger.info("# starting zcached server on tcp://{any} | Workers {}", .{
        context.config.address,
        context.config.workers,
    });

    var employer = Employer.init(allocator, context) catch |err| {
        context.resources.logger.err("# failed to initialize server: {any}", .{err});
        return;
    };
    defer employer.deinit();

    employer.supervise();
}
