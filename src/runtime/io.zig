//! Runtime I/O selection, worker-thread startup, and clock helpers.
const builtin = @import("builtin");
const std = @import("std");

/// The runtime's evented implementation used to back workers.
pub const Evented = @import("evented.zig");

/// A dedicated thread with its own evented backend and thread-local I/O binding.
pub const Worker = struct {
    /// The backend initialized and owned by the worker thread.
    backend: Evented = undefined,
    /// The spawned thread, cleared once joined.
    thread: ?std.Thread = null,
    /// Signals successful backend initialization or captures its failure.
    ready: std.Io.Event = .unset,
    /// Backend initialization error communicated to the starter.
    init_error: ?anyerror = null,

    /// Starts the worker, waits for initialization, then invokes `function`.
    /// The callback receives the worker's I/O interface; startup errors are
    /// returned, while the callback runs until it returns.
    pub fn start(self: *Worker, io: std.Io, allocator: std.mem.Allocator, comptime function: anytype, args: anytype) !void {
        std.debug.assert(self.thread == null);
        self.* = .{};
        const Entry = struct {
            /// Initializes the worker backend, binds its thread-local interface,
            /// and runs the requested callback on this thread.
            fn run(worker: *Worker, parent_io: std.Io, alloc: std.mem.Allocator, arguments: @TypeOf(args)) void {
                worker.backend.init(alloc) catch |err| {
                    worker.init_error = err;
                    worker.ready.set(parent_io);
                    return;
                };
                defer worker.backend.deinit();
                const worker_io = worker.backend.io();
                const previous_io = thread_runtime;
                thread_runtime = worker_io;
                defer thread_runtime = previous_io;
                worker.ready.set(parent_io);
                @call(.auto, function, .{worker_io} ++ arguments);
            }
        };
        self.thread = try std.Thread.spawn(.{}, Entry.run, .{ self, io, allocator, args });
        self.ready.waitUncancelable(io);
        if (self.init_error) |err| {
            self.join();
            return err;
        }
    }

    /// Joins the thread if it is still running; repeated calls are harmless.
    pub fn join(self: *Worker) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }
};

/// Process-wide fallback I/O backend, set by runtime initialization.
pub var runtime: std.Io = undefined;
/// Per-thread override used by worker threads to isolate backend selection.
pub threadlocal var thread_runtime: ?std.Io = null;

/// Selects thread-local I/O first, test I/O in tests, otherwise the runtime backend.
pub fn get() std.Io {
    if (thread_runtime) |io| return io;
    if (builtin.is_test) return std.testing.io;
    return runtime;
}

/// Returns real-clock time in whole seconds using the selected I/O backend.
pub fn timestamp() i64 {
    return std.Io.Clock.real.now(get()).toSeconds();
}

/// Returns awake-clock time in nanoseconds using the selected backend.
pub fn timestampNanoseconds() i96 {
    return std.Io.Clock.awake.now(get()).nanoseconds;
}

/// Sleeps on the awake clock; an unexpected sleep error is treated as fatal.
pub fn sleepNanoseconds(nanoseconds: u64) void {
    get().sleep(.fromNanoseconds(nanoseconds), .awake) catch unreachable;
}
