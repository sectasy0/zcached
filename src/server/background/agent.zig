//! Concurrent task scheduler with FIFO immediate work and time-ordered delayed work.
const std = @import("std");
const runtime_io = @import("runtime_io");
const sync = @import("sync");

const fifo = @import("fifo.zig");
const utils = @import("../utils.zig");

/// Shared state allowing a scheduled handle to cancel and synchronize with its task.
const Cancellation = struct {
    /// Allocator used to free this state after both references are released.
    allocator: std.mem.Allocator,
    // One reference belongs to the handle, one to the queued task's lifetime.
    /// Number of live owners; the final release destroys this allocation.
    references: std.atomic.Value(usize) = .init(2),
    /// Serializes cancellation with callback execution.
    mutex: sync.Mutex = .{},
    /// Set while holding `mutex` to prevent a not-yet-started callback from running.
    canceled: bool = false,

    /// Drops one owner and frees the state when no handle or task retains it.
    fn release(self: *Cancellation) void {
        if (self.references.fetchSub(1, .acq_rel) == 1) self.allocator.destroy(self);
    }
};

/// Handle for canceling a delayed or recurring task and waiting for active execution.
pub const ScheduledTask = struct {
    /// Shared cancellation state; null after deinitialization or when no task is owned.
    cancellation: ?*Cancellation,

    /// Waits for an executing callback and prevents subsequent executions.
    /// Cancellation takes effect after any current callback releases the shared mutex.
    pub fn cancel(self: *ScheduledTask) void {
        const state = self.cancellation orelse return;
        state.mutex.lock();
        defer state.mutex.unlock();
        state.canceled = true;
    }

    /// Cancels the task and releases this handle's reference to its state.
    pub fn deinit(self: *ScheduledTask) void {
        const state = self.cancellation orelse return;
        self.cancel();
        self.cancellation = null;
        state.release();
    }
};

/// Type-erased callback plus timing, argument ownership, and optional cancellation state.
pub const Task = struct {
    /// Callback invoked for each execution; null marks the dequeue shutdown sentinel.
    run: ?*const fn (args: ?*const anyopaque) void,
    /// Cleanup for the cloned callback arguments, called when the task is destroyed.
    destroy: ?*const fn (allocator: std.mem.Allocator, args: ?*const anyopaque) void,

    /// Absolute runtime timestamp when this execution becomes eligible.
    execute_at: i64 = 0,
    /// Repeat interval in timestamp units; zero denotes a one-shot task.
    interval: i64 = 0,

    /// Type-erased, queue-owned callback arguments.
    args: ?*const anyopaque,
    /// Optional shared cancellation state retained for the queued task.
    cancellation: ?*Cancellation = null,

    /// Runs at most once, then frees cloned arguments and cancellation ownership.
    pub fn executeAndDestroy(self: *Task, allocator: std.mem.Allocator) void {
        if (self.run) |run| {
            run(self.args);
            self.run = null;
        }
        self.deinit(allocator);
    }

    /// Releases owned callback arguments and the task's cancellation reference.
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

    /// Invokes the callback without clearing it or releasing task resources.
    pub fn execute(self: *Task) void {
        if (self.run) |run| {
            run(self.args);
        }
    }

    /// Orders tasks by their next scheduled timestamp for the delayed priority queue.
    pub fn compare(context: void, a: Task, b: Task) std.math.Order {
        _ = context;
        return std.math.order(a.execute_at, b.execute_at);
    }
};

/// Thread-safe immediate and delayed queues consumed by the agent's drain thread.
pub const Queue = struct {
    // FIFO for ready to execute tasks
    /// Tasks eligible now, dequeued in insertion order.
    ready: fifo.LinearFifo(Task, .Dynamic),
    // Priority queue for delayed tasks, ordered by execute_at.
    /// Future tasks, with the earliest execution timestamp at the head.
    delayed: std.PriorityQueue(Task, void, Task.compare),
    /// Allocator used by the delayed queue and owned queue storage.
    allocator: std.mem.Allocator,

    // optional capacity limit for testing reschedule failures; ignored in normal operation
    /// Optional test-only cap across both queues; unset in normal use.
    capacity: ?usize = null,

    /// Protects queue contents, stopping state, and wakeup transitions.
    lock: sync.Mutex,

    /// Signals the drain thread after enqueue or stop.
    wakeup: std.Io.Event = .unset,
    /// Rejects new tasks and lets a waiting dequeue return its sentinel.
    stopping: bool = false,

    /// Creates empty task queues using `allocator` for storage.
    pub fn init(allocator: std.mem.Allocator) !Queue {
        return .{
            .ready = .init(allocator),
            .delayed = .initContext({}),
            .allocator = allocator,
            .lock = .{},
        };
    }

    /// Optional per-task timing and cancellation metadata for `enqueue`.
    pub const EnqueueOptions = struct {
        /// Repeat delay; zero schedules immediate, one-shot work.
        interval: i64 = 0,
        /// Shared cancellation state retained by each queued execution.
        cancellation: ?*Cancellation = null,
    };

    /// Clones callback arguments and queues a type-erased wrapper; failure frees its clone.
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
            /// Wrapper's concrete type, used only while constructing task callbacks.
            const Self = @This();
            /// Pointer to the callback argument tuple owned by the queue.
            args: *const @TypeOf(args),

            /// Restores the argument tuple type and invokes the comptime callback.
            fn run(ptr: ?*const anyopaque) void {
                const nonnull_ptr = ptr orelse return;

                const args_ptr: *const @TypeOf(args) = @ptrCast(@alignCast(nonnull_ptr));
                @call(.auto, func, args_ptr.*);
            }

            /// Restores the argument type and frees its queue-owned clone.
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

    /// Transfers task ownership only after a successful enqueue.
    /// On failure, the caller remains responsible for task resources.
    pub fn enqueueTask(self: *Queue, task: Task) !void {
        self.lock.lock();
        defer self.lock.unlock();
        try self.enqueueInner(task);
    }

    /// Inserts a task into the immediate FIFO or timestamp-ordered delayed queue.
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

    /// Removes the earliest eligible task, waiting for enqueue or its deadline as needed.
    /// Returns a null-run sentinel after stop; delayed work is not run during shutdown.
    pub fn dequeue(self: *Queue) Task {
        self.lock.lock();
        defer self.lock.unlock();

        while (true) {
            const next = self.delayed.peek();
            const now = runtime_io.timestamp();
            if (!self.stopping) {
                if (next) |task| {
                    if (task.execute_at <= now) {
                        _ = self.delayed.pop();
                        return task;
                    }
                }
            }
            if (self.ready.readItem()) |task| {
                return task;
            }
            if (self.stopping) return .{ .run = null, .destroy = null, .args = null };

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
    /// Only tuple arguments containing a root `args` struct have their byte-slice fields duplicated.
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
    /// This mirrors the narrow tuple/root-`args` shape handled by the clone helper.
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

    /// Destroys all queued tasks and their owned arguments, then frees queue storage.
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

/// Runs queued work on one background thread and coordinates scheduling and shutdown.
/// Current scheduler type, used by its thread entry point and lifecycle methods.
const Self = @This();

/// Queues immediate and timed callback tasks.
queue: Queue,
/// Drain thread, null until started or after it has joined.
drain_thread: ?std.Thread = null,

/// Number of attempts to enqueue a recurring task's next execution.
reschedule_retries: usize = 5,
/// Pause between recurring-task enqueue retries.
reschedule_retry_delay_ms: u64 = 100,

/// Allocator shared by queue storage and owned task arguments.
allocator: std.mem.Allocator,
/// External process-running flag retained for integration with application lifecycle.
running: *std.atomic.Value(bool),

/// Set by the drain thread once it has entered its worker loop.
started: std.atomic.Value(bool) = .init(false),
/// Protects startup notification.
mutex: sync.Mutex = .{},
/// Wakes `kickoff` after the drain thread sets `started`.
cond: sync.Condition = .{},

/// Initializes the queue and retains the allocator and application running flag.
pub fn init(allocator: std.mem.Allocator, running: *std.atomic.Value(bool)) !Self {
    return .{
        .queue = try .init(allocator),
        .allocator = allocator,
        .running = running,
    };
}

/// Starts the drain thread and waits until it signals that startup completed.
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

/// Schedules a callback with cloned arguments and optional repeat/cancellation settings.
pub fn schedule(self: *Self, comptime func: anytype, args: anytype, options: ?Queue.EnqueueOptions) !void {
    try self.queue.enqueue(self.allocator, func, args, options);
}

/// Schedules cancelable work and returns a handle that synchronizes with its callback.
pub fn scheduleCancelable(self: *Self, comptime func: anytype, args: anytype, interval: i64) !ScheduledTask {
    const state = try self.allocator.create(Cancellation);
    state.* = .{ .allocator = self.allocator };
    errdefer self.allocator.destroy(state);
    try self.schedule(func, args, .{ .interval = interval, .cancellation = state });
    return .{ .cancellation = state };
}

/// Stops and joins the drain thread; ready tasks are processed before it exits.
pub fn stop(self: *Self) void {
    const thread = self.drain_thread orelse return;
    self.queue.lock.lock();
    self.queue.stopping = true;
    self.queue.wakeup.set(runtime_io.get());
    self.queue.lock.unlock();
    thread.join();
    self.drain_thread = null;
}

/// Stops the worker and releases all queued task and queue storage.
pub fn deinit(self: *Self) void {
    self.stop();
    self.queue.deinit(self.allocator);
}

/// Announces startup, dequeues work, and runs or reschedules each task serially.
fn drain(self: *Self) void {
    self.mutex.lock();
    self.started.store(true, .seq_cst);
    self.cond.signal();
    self.mutex.unlock();

    while (true) {
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

/// Enqueues a recurring task at a fixed-rate deadline, retrying transient failures.
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
            if (err == error.AgentStopped) return err;
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
