//! Initializes zcached's runtime, storage, background services, and network server.
const std = @import("std");
const builtin = @import("builtin");
const fs = @import("fs");
const runtime_io = @import("runtime_io");

// Core utilities
const Config = @import("server/config.zig");
const cli = @import("server/cli.zig");
const log = @import("server/logger.zig");

// Networking
const NetworkServer = @import("server/network/server.zig");

// Processing / application logic
const Context = @import("server/context.zig");
const Agent = @import("server/background/agent.zig");

// Storage / memory
const Memory = @import("server/storage/memory.zig");
const snapshot = @import("server/storage/snapshot.zig");
const AOF = @import("server/storage/aof.zig");
const Metrics = @import("server/metrics.zig");
const Auth = @import("server/auth.zig");

pub const panic = std.debug.FullPanic(panicHandler);

/// Indicates whether the server should continue accepting and serving work.
var running: std.atomic.Value(bool) = .init(true);
/// Records the reason why the process entered its shutdown path.
var shutdown_reason: std.atomic.Value(u8) = .init(0);
const ShutdownReason = enum(u8) {
    none = 0,
    sigterm = 1,
    sigint = 2,
};
/// Selects leak-checking debug allocation in safety builds.
const debug_allocator = builtin.mode == .debug or builtin.mode == .safe;

/// Bridges the persistence callback to the active append-only-file handler.
fn appendAOFCommand(ptr: *anyopaque, command: []const @import("protocol/types.zig").ZType) anyerror!void {
    const aof: *AOF = @ptrCast(@alignCast(ptr));
    try aof.appendCommand(command);
}

/// Requests graceful shutdown after a termination signal.
fn handleSig(sig: std.posix.SIG) callconv(.c) void {
    shutdown_reason.store(switch (sig) {
        .INT => @backingInt(ShutdownReason.sigint),
        .TERM => @backingInt(ShutdownReason.sigterm),
        else => @backingInt(ShutdownReason.none),
    }, .seq_cst);
    running.store(false, .seq_cst);
}

/// Writes a panic message and stack trace to the configured log before exiting.
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

/// Builds the process runtime and starts the server using parsed CLI and config.
pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag == .windows) @compileError("windows not supported");

    var gpa: std.heap.DebugAllocator(.{
        .safety = true,
        // .verbose_log = true,
        // .retain_metadata = true,
    }) = .init;
    defer {
        if (debug_allocator and gpa.deinit() == .leak) std.process.exit(255);
    }

    const allocator = if (debug_allocator) gpa.allocator() else std.heap.smp_allocator;

    runtime_io.runtime = init.io;

    const result = cli.Parser.parse(allocator, init.minimal.args) catch {
        cli.Parser.showHelp() catch |err| {
            std.log.err("# failed to show help: {any}", .{err});
            return;
        };
        return;
    };
    defer result.parser.deinit();

    if (!handleArguments(result.args)) return;

    var evented_io: runtime_io.Evented = undefined;
    evented_io.init(allocator) catch |err| {
        std.log.err("# startup failed: evented I/O initialization: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    defer {
        runtime_io.runtime = init.io;
        evented_io.deinit();
    }
    runtime_io.runtime = evented_io.io();

    // Background worker
    var agent: Agent = try .init(allocator, &running);
    defer agent.deinit();

    var logger = log.Logger.init(
        allocator,
        null,
        result.args.@"log-path",
        result.args.sout,
    ) catch |err| {
        std.log.err("# startup failed: logger initialization: {any}", .{err});
        return;
    };
    defer logger.deinit();

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
        logger.err("# startup failed: configuration load: {any}", .{err});
        return;
    };
    defer config.deinit();
    logger.level = switch (config.log.level) {
        .debug => .Debug,
        .info => .Info,
        .warning => .Warning,
        .@"error" => .Error,
    };

    var persister = snapshot.Handler.init(
        allocator,
        config,
        &logger,
        null,
    ) catch |err| {
        logger.err("# startup failed: snapshot handler initialization: {any}", .{err});
        return;
    };
    defer persister.deinit();

    var memory = Memory.init(
        allocator,
        config,
        &persister,
    ) catch |err| {
        logger.err("# startup failed: memory initialization: {any}", .{err});
        return;
    };
    defer memory.deinit();

    agent.kickoff() catch |err| {
        logger.err("# startup failed: background agent initialization: {any}", .{err});
        return;
    };
    defer agent.stop();
    logger.start(&agent) catch |err| {
        std.log.err("# startup failed: logger flush scheduling: {any}", .{err});
        return;
    };

    const aof_enabled = config.aof.flush_strategy != .no;
    const restored = if (aof_enabled)
        persister.loadForReplay(&memory)
    else
        persister.load(&memory);
    restored catch |err| {
        if (err != error.FileNotFound and err != error.InvalidFile) {
            logger.warn("# failed to restore data from snapshot: {any}", .{err});
        } else if (err == error.InvalidFile) {
            if (aof_enabled) {
                logger.warn("# no valid snapshot available; continuing with the AOF", .{});
            } else {
                logger.warn("# no valid snapshot available; starting with empty storage", .{});
            }
        }
    };

    var auth = Auth.init(allocator, config.auth) catch |err| {
        logger.err("# startup failed: auth configuration: {any}", .{err});
        return;
    };
    defer auth.deinit();
    var metrics: Metrics = .{};
    var context = Context{
        .config = &config,
        .resources = .{
            .memory = &memory,
            .aof = null,
            .logger = &logger,
            .agent = &agent,
            .metrics = &metrics,
            .auth = &auth,
        },
        .running = &running,
    };

    var aof = AOF.init(allocator, context) catch |err| {
        logger.err("# startup failed: AOF initialization: {any}", .{err});
        return;
    };
    defer aof.deinit();
    context.resources.aof = .{
        .ptr = &aof,
        .append_command = appendAOFCommand,
    };

    aof.replay() catch |err| {
        logger.err("# startup failed: AOF replay: {any}", .{err});
        return err;
    };

    var expiry_task = agent.scheduleCancelable(Memory.purgeExpired, .{&memory}, 1) catch |err| {
        logger.err("# startup failed: key-expiry scheduling: {any}", .{err});
        return;
    };
    defer expiry_task.deinit();

    aof.start() catch |err| {
        logger.err("# startup failed: AOF flush scheduling: {any}", .{err});
        return;
    };
    persister.start(&agent, &memory) catch |err| {
        logger.err("# startup failed: snapshot scheduling: {any}", .{err});
        return;
    };
    defer persister.stop();

    {
        var server = NetworkServer.init(allocator, evented_io.io(), context) catch |err| {
            logger.err("# startup failed: network server initialization: {any}", .{err});
            return;
        };
        defer server.deinit();
        server.run(evented_io.io());

        switch (@as(ShutdownReason, @fromBackingInt(@intCast(shutdown_reason.load(.seq_cst))))) {
            .sigterm => logger.info("# shutdown requested by SIGTERM", .{}),
            .sigint => logger.info("# shutdown requested by SIGINT", .{}),
            .none => logger.info("# server supervisor stopped; beginning graceful shutdown", .{}),
        }
    }
}

/// Handles early-exit CLI options before server resources are initialized.
fn handleArguments(args: cli.Args) bool {
    if (args.help) {
        cli.Parser.showHelp() catch |err| {
            std.log.err("# failed to show help: {any}", .{err});
            return false;
        };
        return false;
    }

    if (args.version) {
        cli.Parser.showVersion() catch |err| {
            std.log.err("# failed to show version: {any}", .{err});
            return false;
        };
        return false;
    }

    if (args.daemon) {
        const pid = args.pid orelse {
            std.log.err("# missing -pid file path", .{});
            return false;
        };
        const daemon = @import("server/daemon.zig");
        daemon.daemonize(pid);
    }
    return true;
}
