const std = @import("std");

const utils = @import("../utils.zig");

pub const Task = struct {
    run: ?*const fn (args: ?*const anyopaque) void,
    destroy: ?*const fn (allocator: std.mem.Allocator, args: ?*const anyopaque) void,

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
};

pub const Queue = struct {
    const max_tasks = 100;

    tasks: [max_tasks]?Task,
    lock: std.Thread.Mutex,

    not_full: std.Thread.Condition = .{},
    not_empty: std.Thread.Condition = .{},
    timeout: u64 = std.time.ms_per_s * 100_000,

    // pointers for managing the queue
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,

    pub const empty: Queue = .{
        .tasks = @splat(null),
        .lock = .{},
    };

    pub fn enqueue(
        self: *Queue,
        allocator: std.mem.Allocator,
        comptime func: anytype,
        args: anytype,
        // name: []const u8,
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

        var retries: usize = 0;
        const max_retries = 10;

        while (true) {
            if (self.enqueueInner(.{
                .run = Wrapper.run,
                .destroy = Wrapper.destroy,
                .args = @ptrCast(@alignCast(owned_args_ptr)),
            })) {
                break; // Task enqueued successfully
            } else |err| {
                switch (err) {
                    error.Timeout => {
                        if (retries >= max_retries) {
                            releaseOwnership(allocator, owned_args_ptr);
                            return err;
                        }
                        retries += 1;
                        continue; // we need to retry
                    },
                }
            }
        }

        owned_args_ptr = undefined;
    }

    fn enqueueInner(self: *Queue, task: Task) !void {
        while (max_tasks == self.count) {
            try self.not_full.timedWait(&self.lock, self.timeout);
        }

        self.tasks[self.tail] = task;
        self.tail = (self.tail + 1) % max_tasks;
        self.count += 1;

        // Wakeup threads waiting for dequeue
        self.not_empty.broadcast();
    }

    pub fn dequeue(self: *Queue) Task {
        self.lock.lock();
        defer self.lock.unlock();

        while (0 == self.count) {
            self.not_empty.wait(&self.lock);
        }

        const task = self.tasks[self.head].?;
        self.tasks[self.head] = null;
        self.head = (self.head + 1) % max_tasks;
        self.count -= 1;

        // Wakeup threads waiting for enqueue
        self.not_full.broadcast();

        return task;
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

        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const idx = (self.head + i) % max_tasks;
            const task = &self.tasks[idx].?;
            if (task.destroy) |destroy| {
                destroy(allocator, task.args);
            }
        }

        self.head = 0;
        self.tail = 0;
        self.count = 0;
    }
};

const Self = @This();

queue: Queue,
drain_thread: ?std.Thread = null,

allocator: std.mem.Allocator,
running: *std.atomic.Value(bool),

started: std.atomic.Value(bool) = .init(false),
mutex: std.Thread.Mutex = .{},
cond: std.Thread.Condition = .{},

pub fn init(allocator: std.mem.Allocator, running: *std.atomic.Value(bool)) Self {
    return .{
        .queue = .empty,
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

pub fn schedule(self: *Self, comptime func: anytype, args: anytype) !void {
    try self.queue.enqueue(self.allocator, func, args);
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

        task.executeAndDestroy(self.allocator);
    }
}
