//! Runs an isolated local server and benchmark while recording a macOS Time Profiler trace.

const std = @import("std");
const builtin = @import("builtin");

/// Registers a process-scoped notification used to detect trace startup.
extern "c" fn notify_register_check(name: [*:0]const u8, token: *c_int) u32;
/// Checks whether a registered process notification has changed.
extern "c" fn notify_check(token: c_int, changed: *c_int) u32;
/// Releases a notification registration after profiling finishes.
extern "c" fn notify_cancel(token: c_int) u32;

/// Set by the signal handler and polled by the interrupt wait task.
var interrupted: std.atomic.Value(bool) = .init(false);

/// Paths and timing/workload bounds for an isolated profiling run.
const Options = struct {
    /// Server executable to launch inside the results directory.
    server: []const u8 = "zig-out/bin/zcached",
    /// Benchmark executable used to generate load during recording.
    benchmark: []const u8 = "zig-out/bin/benchmark",
    /// New directory for configuration, logs, benchmark output, and trace.
    output: ?[]const u8 = null,
    /// Maximum duration of the Time Profiler recording, in seconds.
    duration: u32 = 30,
    /// Whole-run deadline; must exceed the recording duration.
    timeout: u32 = 600,
    /// Worker threads configured for the temporary server.
    workers: usize = 8,
    /// Simultaneous benchmark connections.
    clients: usize = 32,
    /// Even number of requests issued by each client.
    requests: usize = 2000000,
    /// Number of requests grouped into each benchmark batch.
    pipeline: usize = 64,
    /// Stored and fetched value size in bytes.
    value_size: usize = 20,
    /// Requested local TCP port; zero asks the operating system to choose.
    port: u16 = 0,
};

/// Parses a decimal integer and enforces the inclusive caller-supplied bounds.
fn number(comptime T: type, text: []const u8, min: T, max: T) !T {
    const value = try std.fmt.parseInt(T, text, 10);
    if (value < min or value > max) return error.InvalidOptionValue;
    return value;
}

/// Parses profiling flags and enforces valid workload bounds and timeout ordering.
pub fn parseOptions(args: []const [:0]const u8) !Options {
    var options: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        if (i + 1 == args.len) return error.MissingOptionValue;
        const name = args[i];
        const value = args[i + 1];
        if (std.mem.eql(u8, name, "--server")) {
            options.server = value;
        } else if (std.mem.eql(u8, name, "--benchmark")) {
            options.benchmark = value;
        } else if (std.mem.eql(u8, name, "--output")) {
            options.output = value;
        } else if (std.mem.eql(u8, name, "--duration")) {
            options.duration = try number(u32, value, 1, 3600);
        } else if (std.mem.eql(u8, name, "--timeout")) {
            options.timeout = try number(u32, value, 1, 86400);
        } else if (std.mem.eql(u8, name, "--workers")) {
            options.workers = try number(usize, value, 1, 128);
        } else if (std.mem.eql(u8, name, "--clients")) {
            options.clients = try number(usize, value, 1, 128);
        } else if (std.mem.eql(u8, name, "--requests")) {
            options.requests = try number(usize, value, 2, std.math.maxInt(usize));
            if (options.requests % 2 != 0) return error.InvalidRequestCount;
        } else if (std.mem.eql(u8, name, "--pipeline")) {
            options.pipeline = try number(usize, value, 1, 4096);
        } else if (std.mem.eql(u8, name, "--value-size")) {
            options.value_size = try number(usize, value, 1, 1048576);
        } else if (std.mem.eql(u8, name, "--port")) {
            options.port = try number(u16, value, 0, 65535);
        } else return error.UnknownOption;
    }
    if (options.timeout <= options.duration) return error.TimeoutTooShort;
    return options;
}

/// Typed completions returned by the concurrently monitored children and wait tasks.
const Event = union(enum) {
    /// Process termination status or wait error for the server.
    server: anyerror!std.process.Child.Term,
    /// Process termination status or wait error for the profiler.
    profiler: anyerror!std.process.Child.Term,
    /// Process termination status or wait error for the load generator.
    benchmark: anyerror!std.process.Child.Term,
    /// Result of probing the server's listening endpoint.
    server_ready: anyerror!void,
    /// Result of waiting for the profiler-start notification.
    profiler_ready: anyerror!void,
    /// Deadline completion, represented as a timeout error.
    timeout: anyerror!void,
    /// Signal wait completion, represented as an interruption error.
    interrupt: anyerror!void,
};

/// Waits for the next event, translating server exit, timeout, and interruption into errors.
fn next(select: *std.Io.Select(Event)) !Event {
    const event = try select.await();
    switch (event) {
        .server => |result| {
            std.debug.print("Server exited unexpectedly: {f}\n", .{try result});
            return error.ServerExited;
        },
        .timeout, .interrupt => |result| {
            try result;
            unreachable;
        },
        else => return event,
    }
}

/// Repeatedly probes the reserved endpoint until the server accepts a connection.
/// Returns immediately on non-retryable socket errors or after the bounded startup wait.
fn waitServer(io: std.Io, address: std.Io.net.IpAddress) !void {
    for (0..300) |_| {
        const socket = address.connect(io, .{ .mode = .stream }) catch |err| switch (err) {
            error.ConnectionRefused => {
                try io.sleep(.fromMilliseconds(100), .awake);
                continue;
            },
            else => return err,
        };
        socket.close(io);
        return;
    }
    return error.ServerStartupTimeout;
}

/// Polls the macOS notification token until tracing begins or startup expires.
fn waitProfiler(io: std.Io, token: c_int) !void {
    for (0..600) |_| {
        var changed: c_int = 0;
        if (notify_check(token, &changed) != 0) return error.NotificationFailed;
        if (changed != 0) return;
        try io.sleep(.fromMilliseconds(100), .awake);
    }
    return error.ProfilerStartupTimeout;
}

/// Sleeps for the configured deadline, then reports that the run timed out.
fn waitTimeout(io: std.Io, seconds: u32) !void {
    try io.sleep(.fromSeconds(seconds), .awake);
    return error.RunTimedOut;
}

/// Polls the signal flag until interrupted, then reports cancellation to the selector.
fn waitInterrupt(io: std.Io) !void {
    while (!interrupted.load(.acquire)) try io.sleep(.fromMilliseconds(100), .awake);
    return error.Interrupted;
}

/// Async-signal-safe handler that records a pending termination signal.
fn handleSignal(_: std.posix.SIG) callconv(.c) void {
    interrupted.store(true, .release);
}

/// Converts a non-success child termination into a labeled diagnostic and error.
fn requireSuccess(term: std.process.Child.Term, label: []const u8) !void {
    if (!term.success()) {
        std.debug.print("{s} failed: {f}\n", .{ label, term });
        return error.ChildFailed;
    }
}

/// Reaps a child without relinquishing its PID when the wait operation is canceled.
/// The PID is cleared only after waitpid observes a terminal process status.
pub fn waitChild(child: *std.process.Child, io: std.Io) !std.process.Child.Term {
    std.debug.assert(child.stdin == null and child.stdout == null and child.stderr == null);
    // Canceling Child.wait clears its PID even when the process is still alive.
    while (true) {
        var status: c_int = 0;
        const result = std.c.waitpid(child.id.?, &status, std.c.W.NOHANG);
        if (result > 0) {
            child.id = null;
            const bits: u32 = @bitCast(status);
            if (std.posix.W.IFEXITED(bits)) return .{ .exited = std.posix.W.EXITSTATUS(bits) };
            if (std.posix.W.IFSIGNALED(bits)) return .{ .signal = std.posix.W.TERMSIG(bits) };
            return .{ .unknown = bits };
        }
        if (result < 0) switch (std.posix.errno(result)) {
            .INTR => continue,
            else => |err| {
                std.debug.print("waitpid failed: {s}\n", .{@tagName(err)});
                return error.ChildWaitFailed;
            },
        };
        try io.sleep(.fromMilliseconds(50), .awake);
    }
}

/// Creates isolated server configuration, runs the server/profiler/benchmark lifecycle,
/// preserves diagnostic outputs, and opens the generated trace when all children succeed.
fn run(allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
    const cwd = std.Io.Dir.cwd();
    const server_path = try cwd.realPathFileAlloc(io, options.server, allocator);
    const benchmark_path = try cwd.realPathFileAlloc(io, options.benchmark, allocator);
    const output = options.output orelse try std.fmt.allocPrint(allocator, "zig-out/profile-{d}", .{std.Io.Clock.real.now(io).nanoseconds});
    if (std.fs.path.dirname(output)) |parent| try cwd.createDirPath(io, parent);
    try cwd.createDir(io, output, .default_dir);
    var dir = try cwd.openDir(io, output, .{});
    defer dir.close(io);
    const output_path = try cwd.realPathFileAlloc(io, output, allocator);
    std.debug.print("Profiling results: {s}\n", .{output_path});
    errdefer std.debug.print("Profiling failed; diagnostic logs retained in {s}\n", .{output_path});

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", options.port);
    var reservation = try address.listen(io, .{});
    const bound_address = reservation.socket.address;
    const port = bound_address.getPort();
    reservation.deinit(io);
    const config = try std.fmt.allocPrint(allocator,
        \\.{{
        \\    .address = "127.0.0.1",
        \\    .port = {d},
        \\    .workers = {d},
        \\    .memory = .{{ .limit = 0 }},
        \\    .log_network_payloads = false,
        \\    .tls = .{{ .enabled = false }},
        \\    .aof = .{{ .flush_strategy = .no, .path = "./data/appendonly.aof" }},
        \\}}
        \\
    , .{ port, options.workers });
    try dir.writeFile(io, .{ .sub_path = "config.zon", .data = config });
    const server_log = try dir.createFile(io, "server-output.log", .{ .exclusive = true });
    defer server_log.close(io);
    const profiler_log = try dir.createFile(io, "profiler.log", .{ .exclusive = true });
    defer profiler_log.close(io);
    const results = try dir.createFile(io, "benchmark.txt", .{ .exclusive = true });
    defer results.close(io);

    var server = try std.process.spawn(io, .{
        .argv = &.{ server_path, "--config-path", "config.zon", "--log-path", "server.log" },
        .cwd = .{ .dir = dir },
        .stdin = .ignore,
        .stdout = .{ .file = server_log },
        .stderr = .{ .file = server_log },
    });
    defer server.kill(io);
    const server_pid = server.id.?;
    var profiler: ?std.process.Child = null;
    defer if (profiler) |*child| child.kill(io);
    var benchmark: ?std.process.Child = null;
    defer if (benchmark) |*child| child.kill(io);

    const notification = try std.fmt.allocPrintSentinel(allocator, "org.zcached.profile.{d}", .{server_pid}, 0);
    var token: c_int = undefined;
    if (notify_register_check(notification, &token) != 0) return error.NotificationFailed;
    defer if (notify_cancel(token) != 0) {
        std.debug.print("Failed to release profiler notification\n", .{});
    };
    var changed: c_int = 0;
    if (notify_check(token, &changed) != 0) return error.NotificationFailed;

    var events: [8]Event = undefined;
    var select = std.Io.Select(Event).init(io, &events);
    defer select.cancelDiscard();
    try select.concurrent(.server, waitChild, .{ &server, io });
    try select.concurrent(.server_ready, waitServer, .{ io, bound_address });
    try select.concurrent(.timeout, waitTimeout, .{ io, options.timeout });
    try select.concurrent(.interrupt, waitInterrupt, .{io});
    switch (try next(&select)) {
        .server_ready => |result| try result,
        else => return error.UnexpectedEvent,
    }

    const trace = try std.fs.path.join(allocator, &.{ output_path, "profile.trace" });
    profiler = try std.process.spawn(io, .{
        .argv = &.{
            "xcrun",
            "xctrace",
            "record",
            "--template",
            "Time Profiler",
            "--attach",
            try std.fmt.allocPrint(allocator, "{d}", .{server_pid}),
            "--time-limit",
            try std.fmt.allocPrint(allocator, "{d}s", .{options.duration}),
            "--output",
            trace,
            "--no-prompt",
            "--notify-tracing-started",
            notification,
        },
        .stdin = .ignore,
        .stdout = .{ .file = profiler_log },
        .stderr = .{ .file = profiler_log },
    });
    try select.concurrent(.profiler, waitChild, .{ &profiler.?, io });
    try select.concurrent(.profiler_ready, waitProfiler, .{ io, token });
    switch (try next(&select)) {
        .profiler_ready => |result| try result,
        .profiler => |result| {
            std.debug.print("Profiler exited before benchmark startup: {f}\n", .{try result});
            return error.ProfilerStartupFailed;
        },
        else => return error.UnexpectedEvent,
    }

    benchmark = try std.process.spawn(io, .{
        .argv = &.{
            benchmark_path,
            "--mode",
            "ram",
            "--port",
            try std.fmt.allocPrint(allocator, "{d}", .{port}),
            "--clients",
            try std.fmt.allocPrint(allocator, "{d}", .{options.clients}),
            "--requests",
            try std.fmt.allocPrint(allocator, "{d}", .{options.requests}),
            "--pipeline",
            try std.fmt.allocPrint(allocator, "{d}", .{options.pipeline}),
            "--value-size",
            try std.fmt.allocPrint(allocator, "{d}", .{options.value_size}),
        },
        .stdin = .ignore,
        .stdout = .{ .file = results },
        .stderr = .{ .file = results },
    });
    try select.concurrent(.benchmark, waitChild, .{ &benchmark.?, io });
    var benchmark_done = false;
    var profiler_done = false;
    while (!benchmark_done or !profiler_done) {
        switch (try next(&select)) {
            .benchmark => |result| {
                try requireSuccess(try result, "Benchmark");
                benchmark_done = true;
                if (!profiler_done) std.debug.print("Benchmark completed; recording may include an idle tail.\n", .{});
            },
            .profiler => |result| {
                try requireSuccess(try result, "Profiler");
                profiler_done = true;
                if (!benchmark_done) std.debug.print("Profile saved; waiting for benchmark completion.\n", .{});
            },
            else => return error.UnexpectedEvent,
        }
    }
    var opener = try std.process.spawn(io, .{
        .argv = &.{ "open", trace },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer opener.kill(io);
    try requireSuccess(try waitChild(&opener, io), "Opening profile");
    std.debug.print("Done. Results: {s}/benchmark.txt\nOpen profile: open \"{s}\"\n", .{ output_path, trace });
}

/// Handles help and option errors, installs temporary signal handlers, and starts profiling.
/// Profiling is macOS-only; signal handlers are restored regardless of the run result.
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const usage =
        \\Usage: zig build profile -Doptimize=ReleaseFast -- [options]
        \\  --duration SECONDS   Recording duration (default 30, max 3600)
        \\  --timeout SECONDS    Whole-run deadline (default 600, max 86400)
        \\  --clients N          Benchmark clients (default 32)
        \\  --requests EVEN_N    Requests per client and workload (default 2000000)
        \\  --pipeline N         Requests per batch (default 64)
        \\  --value-size BYTES   Value size (default 20)
        \\  --workers N          Server workers (default 8)
        \\  --port N             Port (default 0: automatically selected)
        \\  --output PATH        New output directory (default zig-out/profile-TIMESTAMP)
        \\  --server PATH        Server executable (supplied by build step)
        \\  --benchmark PATH     Benchmark executable (supplied by build step)
        \\
    ;
    if (args.len > 1 and std.mem.eql(u8, args[args.len - 1], "--help")) {
        std.debug.print("{s}", .{usage});
        return;
    }
    const options = parseOptions(args) catch |err| {
        std.debug.print("{s}", .{usage});
        return err;
    };
    if (builtin.os.tag != .macos) return error.MacOSRequired;
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var old_int: std.posix.Sigaction = undefined;
    var old_term: std.posix.Sigaction = undefined;
    std.posix.sigaction(.INT, &action, &old_int);
    defer std.posix.sigaction(.INT, &old_int, null);
    std.posix.sigaction(.TERM, &action, &old_term);
    defer std.posix.sigaction(.TERM, &old_term, null);
    try run(allocator, init.io, options);
}
