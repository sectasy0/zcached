const std = @import("std");

const utils = @import("../utils.zig");

pub const Task = struct {
    run: ?*const fn (args: ?*const anyopaque) void,
    destroy: ?*const fn (allocator: std.mem.Allocator, args: ?*const anyopaque) void,

    execute_at: i64 = 0,
    interval: i64 = 0,

    args: ?*const anyopaque,

    pub fn executeAndDestroy(self: *Task, allocator: std.mem.Allocator) void {
        if (self.run) |run| {
            run(self.args);
            self.run = null;
        }

        const local_destroy = self.destroy;
        const local_args = self.args;

        self.destroy = null;
        self.args = null;

        if (local_destroy) |destroy_fn| {
            destroy_fn(allocator, local_args);
        }
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
    ready: std.fifo.LinearFifo(Task, .Dynamic),
    // Priority queue for delayed tasks, ordered by execute_at,
    // when the time comes, tasks are moved from delayed to ready.
    delayed: std.PriorityQueue(Task, void, Task.compare),

    // optional capacity limit for testing reschedule failures; ignored in normal operation
    capacity: ?usize = null,

    lock: std.Thread.Mutex,

    not_full: std.Thread.Condition = .{},
    not_empty: std.Thread.Condition = .{},

    pub fn init(allocator: std.mem.Allocator) !Queue {
        return .{
            .ready = .init(allocator),
            .delayed = .init(allocator, void{}),
            .lock = .{},
        };
    }

    pub const EnqueueOptions = struct {
        interval: i64 = 0,
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
            .execute_at = if (options) |opts| std.time.timestamp() + opts.interval else 0,
            .interval = if (options) |opts| opts.interval else 0,
            .args = @ptrCast(@alignCast(owned_args_ptr)),
        })) {
            return; // Task enqueued successfully
        } else |err| {
            releaseOwnership(allocator, owned_args_ptr);
            return err;
        }

        owned_args_ptr = undefined;
    }

    fn enqueueInner(self: *Queue, task: Task) !void {
        std.debug.print("# Capacity check: {any}\n", .{self.capacity});
        if (self.capacity) |cap| {
            const queue_len = self.ready.count + self.delayed.capacity();
            if (queue_len >= cap and task.run != null) return error.QueueFull;
        }

        if (task.execute_at > std.time.timestamp()) {
            try self.delayed.add(task);
        } else {
            try self.ready.writeItem(task);
        }

        // Wakeup threads waiting for dequeue
        self.not_empty.broadcast();
    }

    pub fn dequeue(self: *Queue) Task {
        self.lock.lock();
        defer self.lock.unlock();

        while (true) {
            if (self.ready.readItem()) |task| {
                // Wake up threads waiting to enqueue
                self.not_full.broadcast();
                return task;
            }

            if (self.delayed.peek()) |task| {
                const now = std.time.timestamp();
                // std.debug.print("# Next delayed task at {d}, now {d}\n", .{ task.execute_at, now });

                if (task.execute_at <= now) {
                    std.debug.print("# Moving delayed task scheduled at {d} to ready queue\n", .{task.execute_at});
                    // move to ready queue
                    // (this might fail if the ready queue is full,
                    // but that's okay — space will free up soon)
                    _ = self.ready.writeItem(task) catch {
                        // if adding to the ready queue failed,
                        // try returning the task back to the heap
                        _ = self.delayed.add(task) catch {
                            // if adding back to the heap failed,
                            // the task is lost, but there's nothing we can do
                        };
                        // wait until space becomes available in the ready queue
                        self.not_full.wait(&self.lock);
                        continue;
                    };

                    _ = self.delayed.remove(); // remove from heap

                    continue;
                } else {
                    const wait_ns: u64 = @intCast(task.execute_at - now);
                    self.not_empty.timedWait(&self.lock, wait_ns) catch {};
                    continue;
                }
            }

            // nothing to do, wait for something to be enqueued
            self.not_empty.wait(&self.lock);
        }
    }

    /// Clones ownership of a struct with string fields using the provided allocator.
    /// - Allocates a new copy of `args`.
    /// - Duplicates any `[]u8` or `[]const u8` fields inside `args.args`.
    /// - On failure, frees already-allocated strings.
    /// Returns a pointer to the newly allocated clone.
    fn takeOwnershipByCloning(allocator: std.mem.Allocator, args: anytype) error{OutOfMemory}!*@TypeOf(args) {
        const T = @TypeOf(args);
        const res = try allocator.create(@TypeOf(args));

        if (@typeInfo(T) != .@"struct") {
            res.* = args;
            return res;
        }

        res.* = args;

        switch (@typeInfo(T)) {
            .@"struct" => |s| {
                if (s.is_tuple) {
                    const args_root = @field(res, "0");

                    // on failure, free all strings that were allocated
                    var got_to: usize = 0;
                    errdefer {
                        inline for (std.meta.fields(@TypeOf(args_root)), 0..) |field, i| {
                            if (comptime std.mem.eql(u8, field.name, "args")) {
                                const args_ptr = @field(args_root, field.name);

                                inline for (std.meta.fields(@TypeOf(args_ptr))) |subfield| {
                                    if ((subfield.type == []const u8 or subfield.type == []u8) and i <= got_to) {
                                        const field_ptr = @field(
                                            @field(
                                                @field(res, "0"),
                                                field.name,
                                            ),
                                            subfield.name,
                                        );
                                        allocator.free(field_ptr);
                                    }
                                }
                            }
                        }

                        allocator.destroy(res);
                    }

                    inline for (std.meta.fields(@TypeOf(args_root))) |field| {
                        // dupe all fields of type `[]const u8` or `[]u8`
                        if (comptime std.mem.eql(u8, field.name, "args")) {
                            const args_ptr = @field(args_root, field.name);

                            inline for (std.meta.fields(@TypeOf(args_ptr)), 0..) |subfield, j| {
                                if (subfield.type == []u8 or subfield.type == []const u8) {
                                    const original = @field(args_ptr, subfield.name);
                                    const duped = try allocator.dupe(u8, original);
                                    @field(
                                        @field(
                                            @field(res, "0"),
                                            field.name,
                                        ),
                                        subfield.name,
                                    ) = duped;
                                    got_to = j;
                                }
                            }
                        }
                    }
                }
            },
            else => return res,
        }

        return res;
    }

    /// Releases ownership of a previously cloned struct.
    /// - Frees any `[]u8` or `[]const u8` fields inside `args.args`.
    /// - Destroys the struct allocation.
    fn releaseOwnership(allocator: std.mem.Allocator, args: anytype) void {
        const args_root = @field(args, "0");

        inline for (std.meta.fields(@TypeOf(args_root))) |field| {
            if (comptime std.mem.eql(u8, field.name, "args")) {
                const args_ptr = @field(args_root, field.name);
                const ArgsT = @TypeOf(args_ptr);

                inline for (std.meta.fields(ArgsT)) |subfield| {
                    const sub_ptr = @field(args_ptr, subfield.name);
                    if (subfield.type == []const u8 or subfield.type == []u8) {
                        allocator.free(sub_ptr);
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
            if (task.destroy) |destroy| {
                destroy(allocator, task.args);
            }
        }
        self.delayed.deinit();

        while (self.ready.readItem()) |task| {
            if (task.destroy) |destroy| {
                destroy(allocator, task.args);
            }
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
mutex: std.Thread.Mutex = .{},
cond: std.Thread.Condition = .{},

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

pub fn deinit(self: *Self) void {
    // We will try until poison pill is enqueued, but break as soon as it succeeds.
    self.queue.lock.lock();

    while (true) {
        // Try to insert poison pill. If enqueueInner returns normally -> success -> break.
        // If it errors (timedWait timeout) -> continue and retry.
        self.queue.enqueueInner(.{
            .run = null,
            .destroy = null,
            .args = null,
        }) catch {
            // enqueueInner did a timedWait internally (which released and reacquired lock),
            // and returned an error (timeout). We should retry.
            continue;
        };
        // success
        break;
    }

    // Wake consumer(s) that something is available.
    self.queue.not_empty.broadcast();
    self.queue.lock.unlock();

    if (self.drain_thread) |t| {
        t.join();
        self.drain_thread = null;
    }

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
    const now = std.time.timestamp();

    // compute next based on the previous schedule -> avoids drift
    var next = prev_sched + interval;

    std.debug.print(
        "# Rescheduling cyclic task, next: {d}\n",
        .{next},
    );

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
                "# Failed to reschedule cyclic task (attempt {d}/{d}): {?}\n",
                .{ i + 1, self.reschedule_retries, err },
            );

            // sleep outside of lock
            std.time.sleep(self.reschedule_retry_delay_ms * std.time.ns_per_ms);

            // recompute next execution to avoid burst execution
            rescheduled.execute_at = std.time.timestamp() + interval;

            continue;
        };

        return; // success
    }

    return error.RescheduleFailed;
}
