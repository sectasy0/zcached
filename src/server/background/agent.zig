const std = @import("std");
const runtime_io = @import("runtime_io");
const sync = @import("sync");

const fifo = @import("fifo.zig");
const utils = @import("../utils.zig");

const Cancellation = struct {
    allocator: std.mem.Allocator,
    // One reference belongs to the handle, one to the queued task's lifetime.
    references: std.atomic.Value(usize) = .init(2),
    mutex: sync.Mutex = .{},
    canceled: bool = false,

    fn release(self: *Cancellation) void {
        if (self.references.fetchSub(1, .acq_rel) == 1) self.allocator.destroy(self);
    }
};

pub const ScheduledTask = struct {
    cancellation: ?*Cancellation,

    /// Waits for an executing callback and prevents subsequent executions.
    pub fn cancel(self: *ScheduledTask) void {
        const state = self.cancellation orelse return;
        state.mutex.lock();
        defer state.mutex.unlock();
        state.canceled = true;
    }

    pub fn deinit(self: *ScheduledTask) void {
        const state = self.cancellation orelse return;
        self.cancel();
        self.cancellation = null;
        state.release();
    }
};

pub const Task = struct {
    run: ?*const fn (args: ?*const anyopaque) void,
    destroy: ?*const fn (allocator: std.mem.Allocator, args: ?*const anyopaque) void,

    execute_at: i64 = 0,
    interval: i64 = 0,

    args: ?*const anyopaque,
    cancellation: ?*Cancellation = null,

    pub fn executeAndDestroy(self: *Task, allocator: std.mem.Allocator) void {
        if (self.run) |run| {
            run(self.args);
            self.run = null;
        }
        self.deinit(allocator);
    }

    fn deinit(self: *Task, allocator: std.mem.Allocator) void {
        const local_destroy = self.destroy;
        const local_args = self.args;

        self.destroy = null;
        self.args = null;

        if (local_destroy) |destroy_fn| {
            destroy_fn(allocator, local_args);
        }
        if (self.cancellation) |state| state.release();
        self.cancellation = null;
    }

    pub fn execute(self: *Task) void {
        if (self.run) |run| {
            run(self.args);
        }
    }

    pub fn compare(context: void, a: Task, b: Task) std.math.Order {
        _ = context;
        return std.math.order(a.execute_at, b.execute_at);
    }
};

pub const Queue = struct {
    // FIFO for ready to execute tasks
    ready: fifo.LinearFifo(Task, .Dynamic),
    // Priority queue for delayed tasks, ordered by execute_at.
    delayed: std.PriorityQueue(Task, void, Task.compare),
    allocator: std.mem.Allocator,

    // optional capacity limit for testing reschedule failures; ignored in normal operation
    capacity: ?usize = null,

    lock: sync.Mutex,

    wakeup: std.Io.Event = .unset,
    stopping: bool = false,

    pub fn init(allocator: std.mem.Allocator) !Queue {
        return .{
            .ready = .init(allocator),
            .delayed = .initContext({}),
            .allocator = allocator,
            .lock = .{},
        };
    }

    pub const EnqueueOptions = struct {
        interval: i64 = 0,
        cancellation: ?*Cancellation = null,
    };

    pub fn enqueue(
        self: *Queue,
        allocator: std.mem.Allocator,
        comptime func: anytype,
        args: anytype,
        options: ?EnqueueOptions,
    ) !void {
        self.lock.lock();
        defer self.lock.unlock();

        const Wrapper = struct {
            const Self = @This();
            args: *const @TypeOf(args),

            fn run(ptr: ?*const anyopaque) void {
                const nonnull_ptr = ptr orelse return;

                const args_ptr: *const @TypeOf(args) = @ptrCast(@alignCast(nonnull_ptr));
                @call(.auto, func, args_ptr.*);
            }

            fn destroy(alloc: std.mem.Allocator, ptr: ?*const anyopaque) void {
                const nonnull_ptr = ptr orelse return;

                const args_ptr: *const @TypeOf(args) = @ptrCast(@alignCast(nonnull_ptr));
                releaseOwnership(alloc, args_ptr);
            }
        };

        var owned_args_ptr = try takeOwnershipByCloning(allocator, args);

        if (self.enqueueInner(.{
            .run = Wrapper.run,
            .destroy = Wrapper.destroy,
            .execute_at = if (options) |opts| runtime_io.timestamp() + opts.interval else 0,
            .interval = if (options) |opts| opts.interval else 0,
            .args = @ptrCast(@alignCast(owned_args_ptr)),
            .cancellation = if (options) |opts| opts.cancellation else null,
        })) {
            return; // Task enqueued successfully
        } else |err| {
            releaseOwnership(allocator, owned_args_ptr);
            return err;
        }

        owned_args_ptr = undefined;
    }

    fn enqueueInner(self: *Queue, task: Task) !void {
        if (self.stopping) return error.AgentStopped;
        if (self.capacity) |cap| {
            const queue_len = self.ready.count + self.delayed.count();
            if (queue_len >= cap and task.run != null) return error.QueueFull;
        }

        if (task.execute_at > runtime_io.timestamp()) {
            try self.delayed.push(self.allocator, task);
        } else {
            try self.ready.writeItem(task);
        }

        // Wakeup threads waiting for dequeue
        self.wakeup.set(runtime_io.get());
    }

    pub fn dequeue(self: *Queue) Task {
        self.lock.lock();
        defer self.lock.unlock();

        while (true) {
            if (self.ready.readItem()) |task| {
                return task;
            }
            if (self.stopping) return .{ .run = null, .destroy = null, .args = null };

            const next = self.delayed.peek();
            const now = runtime_io.timestamp();
            if (next) |task| {
                if (task.execute_at <= now) {
                    _ = self.delayed.pop();
                    return task;
                }
            }

            // Reset under the queue lock so enqueue/stop cannot lose a wakeup.
            self.wakeup.reset();
            self.lock.unlock();
            const io = runtime_io.get();
            if (next) |task| {
                self.wakeup.waitTimeout(io, .{
                    .duration = .{ .raw = .fromSeconds(task.execute_at - now), .clock = .awake },
                }) catch |err| switch (err) {
                    error.Timeout => {},
                    error.Canceled => {
                        std.log.err("Database queue wait canceled", .{});
                        self.lock.lock();
                        self.stopping = true;
                        return .{ .run = null, .destroy = null, .args = null };
                    },
                };
            } else {
                self.wakeup.waitUncancelable(io);
            }
            self.lock.lock();
        }
    }

    /// Clones ownership of a struct with string fields using the provided allocator.
    /// - Allocates a new copy of `args`.
    /// - Duplicates any `[]u8` or `[]const u8` fields inside `args.args`.
    /// - On failure, frees already-allocated strings.
    /// Returns a pointer to the newly allocated clone.
    fn takeOwnershipByCloning(allocator: std.mem.Allocator, args: anytype) error{OutOfMemory}!*@TypeOf(args) {
        const T = @TypeOf(args);
        const res = try allocator.create(T);
        errdefer allocator.destroy(res);
        res.* = args;
        if (@typeInfo(T) != .@"struct") return res;
        const info = @typeInfo(T).@"struct";
        if (!info.is_tuple or info.field_names.len == 0) return res;
        const Root = @TypeOf(@field(res, "0"));
        if (@typeInfo(Root) != .@"struct" or !@hasField(Root, "args")) return res;

        const fields = @typeInfo(@TypeOf(@field(res, "0").args)).@"struct";
        var initialized: usize = 0;
        errdefer {
            inline for (fields.field_names, fields.field_types, 0..) |name, Field, index| {
                if ((Field == []const u8 or Field == []u8) and index < initialized) {
                    allocator.free(@field(@field(res, "0").args, name));
                }
            }
        }
        inline for (fields.field_names, fields.field_types, 0..) |name, Field, index| {
            if (Field == []const u8 or Field == []u8) {
                @field(@field(res, "0").args, name) = try allocator.dupe(u8, @field(@field(res, "0").args, name));
            }
            initialized = index + 1;
        }

        return res;
    }

    /// Releases ownership of a previously cloned struct.
    /// - Frees any `[]u8` or `[]const u8` fields inside `args.args`.
    /// - Destroys the struct allocation.
    fn releaseOwnership(allocator: std.mem.Allocator, args: anytype) void {
        const T = @TypeOf(args.*);
        if (@typeInfo(T) == .@"struct") {
            const info = @typeInfo(T).@"struct";
            if (info.is_tuple and info.field_names.len > 0) {
                const args_root = @field(args, "0");
                const Root = @TypeOf(args_root);
                if (@typeInfo(Root) == .@"struct" and @hasField(Root, "args")) {
                    const fields = @typeInfo(@TypeOf(args_root.args)).@"struct";
                    inline for (fields.field_names, fields.field_types) |name, Field| {
                        if (Field == []const u8 or Field == []u8) {
                            allocator.free(@field(args_root.args, name));
                        }
                    }
                }
            }
        }

        allocator.destroy(args);
    }

    pub fn deinit(self: *Queue, allocator: std.mem.Allocator) void {
        self.lock.lock();
        defer self.lock.unlock();

        var iter = self.delayed.iterator();
        while (iter.next()) |task| {
            var owned_task = task;
            owned_task.deinit(allocator);
        }
        self.delayed.deinit(self.allocator);

        while (self.ready.readItem()) |task| {
            var owned_task = task;
            owned_task.deinit(allocator);
        }

        self.ready.deinit();
    }
};

const Self = @This();

queue: Queue,
drain_thread: ?std.Thread = null,

reschedule_retries: usize = 5,
reschedule_retry_delay_ms: u64 = 100,

allocator: std.mem.Allocator,
running: *std.atomic.Value(bool),

started: std.atomic.Value(bool) = .init(false),
mutex: sync.Mutex = .{},
cond: sync.Condition = .{},

pub fn init(allocator: std.mem.Allocator, running: *std.atomic.Value(bool)) !Self {
    return .{
        .queue = try .init(allocator),
        .allocator = allocator,
        .running = running,
    };
}

pub fn kickoff(self: *Self) !void {
    self.drain_thread = try std.Thread.spawn(.{}, Self.drain, .{
        self,
    });

    self.mutex.lock();
    while (!self.started.load(.seq_cst)) {
        self.cond.wait(&self.mutex);
    }
    self.mutex.unlock();
}

pub fn schedule(self: *Self, comptime func: anytype, args: anytype, options: ?Queue.EnqueueOptions) !void {
    try self.queue.enqueue(self.allocator, func, args, options);
}

pub fn scheduleCancelable(self: *Self, comptime func: anytype, args: anytype, interval: i64) !ScheduledTask {
    const state = try self.allocator.create(Cancellation);
    state.* = .{ .allocator = self.allocator };
    errdefer self.allocator.destroy(state);
    try self.schedule(func, args, .{ .interval = interval, .cancellation = state });
    return .{ .cancellation = state };
}

pub fn stop(self: *Self) void {
    const thread = self.drain_thread orelse return;
    self.queue.lock.lock();
    self.queue.stopping = true;
    self.queue.wakeup.set(runtime_io.get());
    self.queue.lock.unlock();
    thread.join();
    self.drain_thread = null;
}

pub fn deinit(self: *Self) void {
    self.stop();
    self.queue.deinit(self.allocator);
}

fn drain(self: *Self) void {
    self.mutex.lock();
    self.started.store(true, .seq_cst);
    self.cond.signal();
    self.mutex.unlock();

    while (self.running.load(.seq_cst)) {
        var task = self.queue.dequeue();
        if (task.run == null) { // poison pill
            return;
        }
        const cancellation = task.cancellation;
        if (cancellation) |state| {
            state.mutex.lock();
            if (state.canceled) {
                state.mutex.unlock();
                task.deinit(self.allocator);
                continue;
            }
        }
        defer if (cancellation) |state| state.mutex.unlock();

        // remember the previous scheduled time (we'll use it to compute the next one
        // so that we get a "fixed-rate" schedule (less drift) instead of "fixed-delay")
        const prev_sched = task.execute_at;
        const interval = task.interval;

        if (interval > 0) {
            // if enqueue fails, we retry a few times with delay
            // here: if we cannot reschedule, we assume the task will not be cyclic anymore
            // and destroy its resources so they don't leak.
            self.rescheduleCyclic(&task, prev_sched, interval) catch {
                task.executeAndDestroy(self.allocator);
                continue;
            };

            // execute the task (without clearing run)
            task.execute();

            continue;
        }

        // if non-cyclic -> execute and destroy resources
        task.executeAndDestroy(self.allocator);
    }
}

fn rescheduleCyclic(self: *Self, task: *Task, prev_sched: i64, interval: i64) !void {
    const now = runtime_io.timestamp();

    // compute next based on the previous schedule -> avoids drift
    var next = prev_sched + interval;

    // if the system slept and "next" is already in the past, catch up
    // (compute the smallest next > now)
    if (next <= now) {
        // how many intervals have passed?
        const missed: i64 = @divFloor(now - prev_sched, interval) + 1;
        next = prev_sched + missed * interval;
    }

    var rescheduled = task.*;
    rescheduled.execute_at = next;

    for (0..self.reschedule_retries) |i| {
        self.queue.lock.lock();
        const result = self.queue.enqueueInner(rescheduled);
        self.queue.lock.unlock();

        _ = result catch |err| {
            std.debug.print(
                "# Failed to reschedule cyclic task (attempt {d}/{d}): {any}\n",
                .{ i + 1, self.reschedule_retries, err },
            );

            // sleep outside of lock
            runtime_io.sleepNanoseconds(self.reschedule_retry_delay_ms * std.time.ns_per_ms);

            // recompute next execution to avoid burst execution
            rescheduled.execute_at = runtime_io.timestamp() + interval;

            continue;
        };

        return; // success
    }

    return error.RescheduleFailed;
}
