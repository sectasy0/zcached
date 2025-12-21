const std = @import("std");

const Agent = @import("../../server/processing/agent.zig");

var running: std.atomic.Value(bool) = .init(true);

var thread_safe_allocator: std.heap.ThreadSafeAllocator = .{
    .child_allocator = std.testing.allocator,
};
const allocator = thread_safe_allocator.allocator();

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

test "deinit via poison pill" {
    var agent: Agent = try .init(allocator, &running);
    var q = &agent.queue;
    try agent.kickoff();

    const func_args = .{ .value = 42 };

    const Wrapper = struct {
        pub fn foo(args: anytype) void {
            std.debug.print("Task executed with {d}\n", .{args.value});
        }
    };

    try q.enqueue(allocator, Wrapper.foo, .{func_args}, .{});

    // deinit should send poison pill and terminate thread
    agent.deinit();
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

    std.Thread.sleep(3 * std.time.ns_per_s);
    agent.deinit();
    try std.testing.expect(counter >= 2);
}

test "cyclic reschedule fails when enqueueInner times out" {
    var agent: Agent = try .init(allocator, &running);
    var q = &agent.queue;

    q.capacity = 1;

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
    std.Thread.sleep(3 * std.time.ns_per_s);

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
    std.Thread.sleep(100 * std.time.ns_per_ms);

    q.capacity = null;

    std.Thread.sleep(2 * std.time.ns_per_s);

    agent.deinit();

    // Task should execute multiple times
    try std.testing.expect(counter >= 2);
}
