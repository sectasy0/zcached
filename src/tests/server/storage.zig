const std = @import("std");

const ContextFixture = @import("../fixtures.zig").ContextFixture;
const types = @import("../../protocol/types.zig");
const helper = @import("../helper.zig");

test "should get existing and not get non-existing key" {
    var fixture = try ContextFixture.init();
    fixture.create_memory_storage();
    defer fixture.deinit();

    try helper.setup_storage(&fixture.memory_storage.?);

    try std.testing.expectEqual(fixture.memory_storage.?.get("foo"), types.ZType{ .int = 42 });
    try std.testing.expectEqual(fixture.memory_storage.?.get("foo2"), types.ZType{ .float = 123.45 });
    try std.testing.expectEqual(fixture.memory_storage.?.get("foo3"), types.ZType{ .bool = true });
    try std.testing.expectEqual(fixture.memory_storage.?.get("foo4"), types.ZType{ .null = void{} });
    // we have to compare values cause it's not same place in memory
    try std.testing.expectEqualStrings((try fixture.memory_storage.?.get("foo5")).sstr, helper.SIMPLE_STRING);
    try std.testing.expectEqualStrings((try fixture.memory_storage.?.get("bar")).str, helper.STRING);

    // array
    var array = try helper.setup_array(fixture.allocator);
    defer array.deinit();

    try fixture.memory_storage.?.put("foo6", .{ .array = array });

    const getted = try fixture.memory_storage.?.get("foo6");
    try helper.expectEqualZTypes(getted, .{ .array = array });

    // map
    var map = try helper.setup_map(fixture.allocator);
    defer map.deinit();

    try fixture.memory_storage.?.put("foo7", .{ .map = map });

    const getted_map = try fixture.memory_storage.?.get("foo7");
    try helper.expectEqualZTypes(getted_map, .{ .map = map });

    try std.testing.expectEqual(fixture.memory_storage.?.get("baz"), error.NotFound);
}

test "should delete existing key" {
    var fixture = try ContextFixture.init();
    fixture.create_memory_storage();
    defer fixture.deinit();

    const string = "Die meisten Menschen sind nichts als Bauern auf einem Schachbrett, das von einer unbekannten Hand geführt wird.";
    const value: types.ZType = .{ .str = @constCast(string) };

    try fixture.memory_storage.?.put("foo", .{ .int = 42 });
    try fixture.memory_storage.?.put("bar", value);

    try std.testing.expectEqual(fixture.memory_storage.?.delete("foo"), true);
    try std.testing.expectEqual(fixture.memory_storage.?.get("foo"), error.NotFound);
    try std.testing.expectEqualStrings((try fixture.memory_storage.?.get("bar")).str, value.str);
}

test "should not delete non-existing key" {
    var fixture = try ContextFixture.init();
    fixture.create_memory_storage();
    defer fixture.deinit();

    try std.testing.expectEqual(fixture.memory_storage.?.delete("foo"), false);
}

test "should flush storage" {
    var fixture = try ContextFixture.init();
    fixture.create_memory_storage();
    defer fixture.deinit();

    const string = "Es gibt Momente im Leben, da muss man verstehen, dass die Entscheidungen, die man trifft, nicht nur das eigene Schicksal angehen.";
    const value: types.ZType = .{ .str = @constCast(string) };

    try fixture.memory_storage.?.put("foo", .{ .int = 42 });
    try fixture.memory_storage.?.put("bar", value);

    fixture.memory_storage.?.flush();

    try std.testing.expectEqual(fixture.memory_storage.?.get("foo"), error.NotFound);
    try std.testing.expectEqual(fixture.memory_storage.?.get("bar"), error.NotFound);
}

test "should not store error" {
    var fixture = try ContextFixture.init();
    fixture.create_memory_storage();
    defer fixture.deinit();

    const err_value = .{ .err = .{ .message = "random error" } };
    try std.testing.expectEqual(fixture.memory_storage.?.put("test", err_value), error.CantInsertError);
}

test "should return error.MemoryLimitExceeded" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    fixture.config.maxmemory = 1048576;
    fixture.create_memory_storage();

    var arena = std.heap.ArenaAllocator.init(fixture.allocator);
    defer arena.deinit();

    const string = "Was wir wissen, ist ein Tropfen, was wir nicht wissen, ein Ozean.";
    const value: types.ZType = .{ .str = @constCast(string) };
    for (0..6554) |i| {
        const key = try std.fmt.allocPrint(arena.allocator(), "key-{d}", .{i});
        try fixture.memory_storage.?.put(key, value);
    }

    try std.testing.expectEqual(fixture.memory_storage.?.put("test key", value), error.MemoryLimitExceeded);
}

test "should not return error.MemoryLimitExceed when max but deleted some" {
    var fixture = try ContextFixture.init();
    fixture.create_memory_storage();
    defer fixture.deinit();

    fixture.config.maxmemory = 1048576;

    var arena = std.heap.ArenaAllocator.init(fixture.allocator);
    defer arena.deinit();
    // const utils = @import("../../server/utils.zig");
    // const tracking = utils.ptrCast(TracingAllocator, storage.allocator.ptr);

    const string = "Was wir wissen, ist ein Tropfen, was wir nicht wissen, ein Ozean.";
    const value: types.ZType = .{ .str = @constCast(string) };
    for (0..1) |i| {
        const key = try std.fmt.allocPrint(arena.allocator(), "key-{d}", .{i});
        try fixture.memory_storage.?.put(key, value);
    }

    const result = fixture.memory_storage.?.put("test key", value);

    try std.testing.expectEqual(void{}, result);
}
