const std = @import("std");

const fixtures = @import("../fixtures.zig");
const ContextFixture = fixtures.ContextFixture;

const types = @import("../../protocol/types.zig");
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
    try std.testing.expectEqual(fixture.memory.?.put("test", err_value), error.CantInsertError);
}

test "should return error.MemoryLimitExceeded" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    fixture.config.maxmemory = 1048576;
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
    try fixture.create_memory();

    fixture.config.maxmemory = 1048576;

    var arena = std.heap.ArenaAllocator.init(fixture.allocator);
    defer arena.deinit();
    // const utils = @import("../../server/utils.zig");
    // const tracking = utils.ptrCast(TracingAllocator, storage.allocator.ptr);

    const string = "Was wir wissen, ist ein Tropfen, was wir nicht wissen, ein Ozean.";
    const value: types.ZType = .{ .str = @constCast(string) };
    for (0..1) |i| {
        const key = try std.fmt.allocPrint(arena.allocator(), "key-{d}", .{i});
        try fixture.memory.?.put(key, value);
    }

    const result = fixture.memory.?.put("test key", value);

    try std.testing.expectEqual(void{}, result);
}

test "should rename key" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var memory = &fixture.memory.?;

    try memory.put("testkey", .{ .float = 10.50 });
    try memory.rename("testkey", "test2");

    try helper.expectEqualZTypes(try memory.get("test2"), .{ .float = 10.50 });
    try std.testing.expectEqual(memory.get("testkey"), error.NotFound);
}

test "should rename overwrite an existing key" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var memory = &fixture.memory.?;

    try memory.put("testkey", .{ .bool = true });
    try memory.put("key", .{ .bool = false });
    try memory.rename("key", "testkey");

    try helper.expectEqualZTypes(try memory.get("testkey"), .{ .bool = false });
    try std.testing.expectEqual(memory.get("key"), error.NotFound);
}

test "should rename return error.MemoryLimitExceeded when new key is bigger" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();

    fixture.config.maxmemory = 1;
    try fixture.create_memory();

    var memory = &fixture.memory.?;

    try memory.put("normalkey", .{ .bool = true });

    try std.testing.expectEqual(memory.rename("normalkey", "longeerkey"), error.MemoryLimitExceeded);

    // This should be okay.
    try memory.rename("normalkey", "key");
    try helper.expectEqualZTypes(try memory.get("key"), .{ .bool = true });
}

test "should rename return error.NotFound" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    try std.testing.expectEqual(fixture.memory.?.rename("test", "test2"), error.NotFound);
}
