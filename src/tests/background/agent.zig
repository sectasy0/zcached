const std = @import("std");
const runtime_io = @import("runtime_io");

const Agent = @import("../../server/background/agent.zig");

var running: std.atomic.Value(bool) = .init(true);

const allocator = std.testing.allocator;

test "delayed database tasks do not block immediate work or shutdown" {
    const io = runtime_io.get();
    var agent = try Agent.init(allocator, &running);
    defer agent.deinit();
    var delayed = try agent.scheduleCancelable(struct {
        fn run() void {}
    }.run, .{}, 60);
    defer delayed.deinit();
    try agent.kickoff();
    runtime_io.sleepNanoseconds(20 * std.time.ns_per_ms);

    var completed: std.Io.Event = .unset;
    const Marker = struct {
        fn run(event: *std.Io.Event) void {
            event.set(runtime_io.get());
        }
    };
    try agent.schedule(Marker.run, .{&completed}, .{});
    try completed.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(500), .clock = .awake } });
    const start = std.Io.Clock.awake.now(io);
    agent.stop();
    try std.testing.expect(start.untilNow(io, .awake).toMilliseconds() < 500);
}

test "canceling a scheduled task waits for its running callback" {
    const io = runtime_io.get();
    var agent = try Agent.init(allocator, &running);
    defer agent.deinit();
    var entered: std.Io.Event = .unset;
    var release: std.Io.Event = .unset;
    defer release.set(io);
    const Blocker = struct {
        fn run(started: *std.Io.Event, finish: *std.Io.Event) void {
            started.set(runtime_io.get());
            finish.waitUncancelable(runtime_io.get());
        }
    };
    var scheduled = try agent.scheduleCancelable(Blocker.run, .{ &entered, &release }, 0);
    defer {
        release.set(io);
        scheduled.deinit();
    }
    try agent.kickoff();
    try entered.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } });

    var canceled: std.Io.Event = .unset;
    const Cancel = struct {
        fn run(task: *Agent.ScheduledTask, finished: *std.Io.Event) void {
            task.cancel();
            finished.set(runtime_io.get());
        }
    };
    var cancel = try io.concurrent(Cancel.run, .{ &scheduled, &canceled });
    defer {
        release.set(io);
        cancel.cancel(io);
    }
    try std.testing.expectError(error.Timeout, canceled.waitTimeout(io, .{
        .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake },
    }));
    release.set(io);
    try canceled.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } });
}

test "enqueue and dequeue works" {
    var q: Agent.Queue = try .init(allocator);

    const func_args = .{ .value = 42 };

    const Wrapper = struct {
        pub fn foo(args: anytype) void {
            std.debug.print("Task executed with {d}\n", .{args.value});
        }
    };

    try q.enqueue(allocator, Wrapper.foo, .{func_args}, .{});

    var task = q.dequeue();
    task.executeAndDestroy(allocator);
    q.deinit(allocator);
}

test "stop drains queued tasks and rejects new tasks before deinit" {
    var agent: Agent = try .init(allocator, &running);
    defer agent.deinit();
    var q = &agent.queue;
    try agent.kickoff();

    var count: usize = 0;
    const Wrapper = struct {
        pub fn foo(args: anytype) void {
            args.count.* += 1;
        }
    };

    try q.enqueue(allocator, Wrapper.foo, .{.{ .count = &count }}, .{});
    agent.stop();
    agent.stop();
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectError(error.AgentStopped, q.enqueue(allocator, Wrapper.foo, .{.{ .count = &count }}, .{}));
}

test "multiple tasks enqueued without drain thread" {
    var agent: Agent = try .init(allocator, &running);
    var q = &agent.queue;

    var counter: usize = 0;
    const Wrapper = struct {
        pub fn foo(args: anytype) void {
            std.debug.print("Task executed with {d}\n", .{args.value});
            args.counter.* += args.value;
        }
    };

    var result: error{ Timeout, OutOfMemory }!void = undefined;

    for (0..101) |n| {
        result = try q.enqueue(
            allocator,
            Wrapper.foo,
            .{.{ .value = n, .counter = &counter }},
            .{},
        );
    }

    agent.deinit();
    try std.testing.expectEqual(0, counter);
    try std.testing.expectEqual(result, void{});
}

test "multiple tasks enqueued not full" {
    var agent: Agent = try .init(allocator, &running);
    var q = &agent.queue;

    try agent.kickoff();

    var counter: usize = 0;
    const Wrapper = struct {
        pub fn foo(args: anytype) void {
            args.counter.* += args.value;
        }
    };

    for (0..101) |n| {
        try q.enqueue(
            allocator,
            Wrapper.foo,
            .{.{ .value = n, .counter = &counter }},
            .{},
        );
    }

    agent.deinit();
    try std.testing.expectEqual(5050, counter);
}

test "multiple tasks enqueued" {
    var agent: Agent = try .init(allocator, &running);
    var q = &agent.queue;

    try agent.kickoff();

    var counter: usize = 0;
    const Wrapper = struct {
        pub fn foo(args: anytype) void {
            args.counter.* += args.value;
        }
    };

    for (0..1000) |n| {
        // var buff: [4096]u8 = undefined;
        // const name = try std.fmt.bufPrint(&buff, "task_{d}", .{n});
        try q.enqueue(
            allocator,
            Wrapper.foo,
            .{.{ .value = n, .counter = &counter }},
            // name,
            .{},
        );
    }

    agent.deinit();
    try std.testing.expectEqual(499500, counter);
}

test "enqueue allocated arg and free before execution" {
    var q: Agent.Queue = try .init(allocator);

    const aaa: []u8 = try allocator.alloc(u8, 23);
    @memcpy(aaa, "Hello, allocated world!");

    const Wrapper = struct {
        pub fn foo(args: anytype) void {
            std.debug.print("Task executed with {any}\n", .{args.args});
        }
    };

    const queue_args = .{ .format = "", .args = .{aaa} };
    try q.enqueue(allocator, Wrapper.foo, .{queue_args}, .{});
    allocator.free(queue_args.args[0]);

    var task = q.dequeue();
    task.executeAndDestroy(allocator);
    q.deinit(allocator);
}

test "enqueue tasks with interval" {
    var agent: Agent = try .init(allocator, &running);
    var q = &agent.queue;

    const interval_sec = 1;

    var counter: usize = 0;
    const Wrapper = struct {
        pub fn foo(args: anytype) void {
            std.debug.print("Task executed with {d}\n", .{args.value});
            args.counter.* += args.value;
        }
    };

    try q.enqueue(
        allocator,
        Wrapper.foo,
        .{.{ .value = 1, .counter = &counter }},
        .{ .interval = interval_sec },
    );

    try agent.kickoff();

    runtime_io.sleepNanoseconds(3 * std.time.ns_per_s);
    agent.deinit();
    try std.testing.expect(counter >= 2);
}

test "cyclic reschedule fails when enqueueInner times out" {
    var agent: Agent = try .init(allocator, &running);
    var q = &agent.queue;

    agent.reschedule_retry_delay_ms = 5;

    var counter: usize = 0;
    var blocker_counter: usize = 0;

    const Wrapper = struct {
        pub fn foo(args: anytype) void {
            args.counter.* += 1;
        }
    };

    // Enqueue one cyclic task
    try q.enqueue(
        allocator,
        Wrapper.foo,
        .{.{ .counter = &counter }},
        .{ .interval = 1 },
    );

    // Occupy one queue slot with a far-future delayed task so every
    // cyclic reschedule attempt hits QueueFull while capacity is 1.
    try q.enqueue(
        allocator,
        Wrapper.foo,
        .{.{ .counter = &blocker_counter }},
        .{ .interval = 60 },
    );

    q.capacity = 1;

    // Start the worker
    try agent.kickoff();

    // Give some time for the worker to attempt reschedule
    runtime_io.sleepNanoseconds(3 * std.time.ns_per_s);

    agent.deinit();

    // Task should execute exactly once (initial execution)
    try std.testing.expectEqual(1, counter);
}

test "cyclic reschedule succeeds after retries" {
    var agent: Agent = try .init(allocator, &running);
    var q = &agent.queue;

    q.capacity = 2;

    agent.reschedule_retry_delay_ms = 5;

    var counter: usize = 0;

    const Wrapper = struct {
        pub fn foo(args: anytype) void {
            args.counter.* += 1;
        }
    };

    // Enqueue one cyclic task
    try q.enqueue(
        allocator,
        Wrapper.foo,
        .{.{ .counter = &counter }},
        .{ .interval = 1 },
    );

    // Start the worker
    try agent.kickoff();

    // Give some time for the worker to attempt reschedule
    runtime_io.sleepNanoseconds(100 * std.time.ns_per_ms);

    q.capacity = null;

    runtime_io.sleepNanoseconds(2 * std.time.ns_per_s);

    agent.deinit();

    // Task should execute multiple times
    try std.testing.expect(counter >= 2);
}
