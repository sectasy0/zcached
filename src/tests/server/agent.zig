const std = @import("std");

const Agent = @import("../../server/processing/agent.zig");

var running: std.atomic.Value(bool) = .init(true);

test "enqueue and dequeue works" {
    var q: Agent.Queue = .empty;

    const func_args = .{ .value = 42 };

    const Wrapper = struct {
        pub fn foo(args: anytype) void {
            std.debug.print("Task executed with {d}\n", .{args.value});
        }
    };

    try q.enqueue(std.testing.allocator, Wrapper.foo, .{func_args});

    var task = q.dequeue();
    task.executeAndDestroy(std.testing.allocator);
    q.deinit(std.testing.allocator);
}

test "deinit via poison pill" {
    var agent: Agent = .init(std.testing.allocator, &running);
    var q = &agent.queue;
    try agent.kickoff();

    const func_args = .{ .value = 42 };

    const Wrapper = struct {
        pub fn foo(args: anytype) void {
            std.debug.print("Task executed with {d}\n", .{args.value});
        }
    };

    try q.enqueue(std.testing.allocator, Wrapper.foo, .{func_args});

    // deinit should send poison pill and terminate thread
    agent.deinit();
}

test "multiple tasks enqueued without drain thread" {
    var agent: Agent = .init(std.testing.allocator, &running);
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
        result = q.enqueue(
            std.testing.allocator,
            Wrapper.foo,
            .{.{ .value = n, .counter = &counter }},
        );
    }

    agent.deinit();
    try std.testing.expectEqual(0, counter);
    try std.testing.expectEqual(result, error.Timeout);
}

test "multiple tasks enququed not full" {
    var agent: Agent = .init(std.testing.allocator, &running);
    var q = &agent.queue;

    try agent.kickoff();

    var counter: usize = 0;
    const Wrapper = struct {
        pub fn foo(args: anytype) void {
            args.counter.* += args.value;
        }
    };

    for (0..50) |n| {
        try q.enqueue(
            std.testing.allocator,
            Wrapper.foo,
            .{.{ .value = n, .counter = &counter }},
        );
    }

    agent.deinit();
    try std.testing.expectEqual(1225, counter);
}

test "multiple tasks enqueued" {
    var agent: Agent = .init(std.testing.allocator, &running);
    var q = &agent.queue;

    try agent.kickoff();

    var counter: usize = 0;
    const Wrapper = struct {
        pub fn foo(args: anytype) void {
            args.counter.* += args.value;
        }
    };

    for (0..500) |n| {
        try q.enqueue(
            std.testing.allocator,
            Wrapper.foo,
            .{.{ .value = n, .counter = &counter }},
        );
    }

    agent.deinit();
    try std.testing.expectEqual(124750, counter);
}

test "enqueue allocated arg and free before execution" {
    var q: Agent.Queue = .empty;

    const aaa: []u8 = try std.testing.allocator.alloc(u8, 23);
    @memcpy(aaa, "Hello, allocated world!");

    const Wrapper = struct {
        pub fn foo(args: anytype) void {
            std.debug.print("Task executed with {any}\n", .{args.args});
        }
    };

    const queue_args = .{ .format = "", .args = .{aaa} };
    try q.enqueue(std.testing.allocator, Wrapper.foo, .{queue_args});
    std.testing.allocator.free(queue_args.args[0]);

    var task = q.dequeue();
    task.executeAndDestroy(std.testing.allocator);
    q.deinit(std.testing.allocator);
}
