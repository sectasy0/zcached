const builtin = @import("builtin");
const std = @import("std");

pub const Evented = @import("evented.zig");

pub const Worker = struct {
    backend: Evented = undefined,
    thread: ?std.Thread = null,
    ready: std.Io.Event = .unset,
    init_error: ?anyerror = null,

    pub fn start(self: *Worker, io: std.Io, allocator: std.mem.Allocator, comptime function: anytype, args: anytype) !void {
        std.debug.assert(self.thread == null);
        self.* = .{};
        const Entry = struct {
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

    pub fn join(self: *Worker) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }
};

pub var runtime: std.Io = undefined;
pub threadlocal var thread_runtime: ?std.Io = null;

pub fn get() std.Io {
    if (thread_runtime) |io| return io;
    if (builtin.is_test) return std.testing.io;
    return runtime;
}

pub fn timestamp() i64 {
    return std.Io.Clock.real.now(get()).toSeconds();
}

pub fn timestampNanoseconds() i96 {
    return std.Io.Clock.awake.now(get()).nanoseconds;
}

pub fn sleepNanoseconds(nanoseconds: u64) void {
    get().sleep(.fromNanoseconds(nanoseconds), .awake) catch unreachable;
}
