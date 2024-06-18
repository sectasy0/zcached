const std = @import("std");

const fixtures = @import("../fixtures.zig");
const ContextFixture = fixtures.ContextFixture;
const TracingAllocator = @import("../../server/tracing.zig");

const types = @import("../../protocol/types.zig");
const utils = @import("../../server/utils.zig");
const helper = @import("../helper.zig");

test "should get existing and not get non-existing key" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    try helper.setup_storage(&fixture.memory.?);

    try std.testing.expectEqual(fixture.memory.?.get("foo"), types.ZType{ .int = 42 });
    try std.testing.expectEqual(fixture.memory.?.get("foo2"), types.ZType{ .float = 123.45 });
    try std.testing.expectEqual(fixture.memory.?.get("foo3"), types.ZType{ .bool = true });
    try std.testing.expectEqual(fixture.memory.?.get("foo4"), types.ZType{ .null = void{} });
    // we have to compare values cause it's not same place in memory
    try std.testing.expectEqualStrings((try fixture.memory.?.get("foo5")).sstr, helper.SIMPLE_STRING);
    try std.testing.expectEqualStrings((try fixture.memory.?.get("bar")).str, helper.STRING);

    // array
    var array = try helper.setup_array(fixture.allocator);
    defer array.deinit();

    try fixture.memory.?.put("foo6", .{ .array = array });

    const getted = try fixture.memory.?.get("foo6");
    try helper.expectEqualZTypes(getted, .{ .array = array });

    // map
    var map = try helper.setup_map(fixture.allocator);
    defer map.deinit();

    try fixture.memory.?.put("foo7", .{ .map = map });

    const getted_map = try fixture.memory.?.get("foo7");
    try helper.expectEqualZTypes(getted_map, .{ .map = map });

    try std.testing.expectEqual(fixture.memory.?.get("baz"), error.NotFound);
}

test "should delete existing key" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    const string = "Die meisten Menschen sind nichts als Bauern auf einem Schachbrett, das von einer unbekannten Hand geführt wird.";
    const value: types.ZType = .{ .str = @constCast(string) };

    try fixture.memory.?.put("foo", .{ .int = 42 });
    try fixture.memory.?.put("bar", value);

    try std.testing.expectEqual(fixture.memory.?.delete("foo"), true);
    try std.testing.expectEqual(fixture.memory.?.get("foo"), error.NotFound);
    try std.testing.expectEqualStrings((try fixture.memory.?.get("bar")).str, value.str);
}

test "should not delete non-existing key" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    try std.testing.expectEqual(fixture.memory.?.delete("foo"), false);
}

test "should flush storage" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    const string = "Es gibt Momente im Leben, da muss man verstehen, dass die Entscheidungen, die man trifft, nicht nur das eigene Schicksal angehen.";
    const value: types.ZType = .{ .str = @constCast(string) };

    try fixture.memory.?.put("foo", .{ .int = 42 });
    try fixture.memory.?.put("bar", value);

    fixture.memory.?.flush();

    try std.testing.expectEqual(fixture.memory.?.get("foo"), error.NotFound);
    try std.testing.expectEqual(fixture.memory.?.get("bar"), error.NotFound);
}

test "should not store error" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    const err_value = .{ .err = .{ .message = "random error" } };
    try std.testing.expectEqual(fixture.memory.?.put("test", err_value), error.InvalidValue);
}

test "should return error.MemoryLimitExceeded" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    fixture.config.maxmemory = 1804460;
    try fixture.create_memory();

    var arena = std.heap.ArenaAllocator.init(fixture.allocator);
    defer arena.deinit();

    const string = "Was wir wissen, ist ein Tropfen, was wir nicht wissen, ein Ozean.";
    const value: types.ZType = .{ .str = @constCast(string) };
    for (0..6554) |i| {
        const key = try std.fmt.allocPrint(arena.allocator(), "key-{d}", .{i});
        try fixture.memory.?.put(key, value);
    }

    try std.testing.expectEqual(fixture.memory.?.put("test key", value), error.MemoryLimitExceeded);
}

test "should not return error.MemoryLimitExceed when max but deleted some" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    fixture.config.maxmemory = 1880;
    try fixture.create_memory();

    var arena = std.heap.ArenaAllocator.init(fixture.allocator);
    defer arena.deinit();

    const string = "Was wir wissen, ist ein Tropfen, was wir nicht wissen, ein Ozean.";
    const value: types.ZType = .{ .str = @constCast(string) };
    for (0..8) |i| {
        const key = try std.fmt.allocPrint(arena.allocator(), "key-{d}", .{i});
        fixture.memory.?.put(key, value) catch {};
    }

    for (0..3) |i| {
        const key = try std.fmt.allocPrint(arena.allocator(), "key-{d}", .{i});

        _ = fixture.memory.?.delete(key);
    }

    const result = fixture.memory.?.put("test key", value);

    try std.testing.expectEqual(void{}, result);
}

test "memory should not grow if key overriden with put" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    try helper.setup_storage(&fixture.memory.?);

    var arena = std.heap.ArenaAllocator.init(fixture.allocator);
    defer arena.deinit();

    const string = "Was wir wissen, ist ein Tropfen, was wir nicht wissen, ein Ozean.";
    const value: types.ZType = .{ .str = @constCast(string) };
    for (0..8) |i| {
        const key = try std.fmt.allocPrint(arena.allocator(), "key-{d}", .{i});
        fixture.memory.?.put(key, value) catch {};
    }

    const tracking = utils.ptrCast(
        TracingAllocator,
        fixture.memory.?.allocator.ptr,
    );

    const before_put = tracking.real_size;
    try fixture.memory.?.put("key-1", value);
    try fixture.memory.?.put("key-2", value);

    try std.testing.expectEqual(before_put, tracking.real_size);
}
