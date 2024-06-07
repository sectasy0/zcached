const std = @import("std");
const helper = @import("../helper.zig");

const fixtures = @import("../fixtures.zig");
const ContextFixture = fixtures.ContextFixture;

const ZType = @import("../../protocol/types.zig").ZType;
const commands = @import("../../server/processing/commands.zig");

test "should handle SET command" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var cmd_handler = commands.Handler.init(fixture.allocator, &fixture.memory.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("SET") });
    try command_set.append(.{ .str = @constCast("key") });
    try command_set.append(.{ .str = @constCast("value") });

    const result = cmd_handler.process(&command_set);

    try std.testing.expectEqual(result.ok, ZType{ .sstr = @constCast("OK") });
    try std.testing.expectEqualStrings((try fixture.memory.?.get("key")).str, @constCast("value"));
}

test "should SET return error.InvalidCommand when passed 2 args" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var cmd_handler = commands.Handler.init(fixture.allocator, &fixture.memory.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("SET") });
    try command_set.append(.{ .str = @constCast("key") });

    const result = cmd_handler.process(&command_set);

    try std.testing.expectEqual(result.err, error.InvalidCommand);
}

test "should SET return error.InvalidCommand when passed 1 args" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var cmd_handler = commands.Handler.init(fixture.allocator, &fixture.memory.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("SET") });

    const result = cmd_handler.process(&command_set);

    try std.testing.expectEqual(result.err, error.InvalidCommand);
}

test "should handle GET command" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var cmd_handler = commands.Handler.init(fixture.allocator, &fixture.memory.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try fixture.memory.?.put("key", .{ .str = @constCast("value") });

    try command_set.append(.{ .str = @constCast("GET") });
    try command_set.append(.{ .str = @constCast("key") });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqualStrings(result.ok.str, @constCast("value"));
}

test "should SET return error.InvalidCommand when missing key" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    try fixture.memory.?.put("key", .{ .str = @constCast("value") });

    var cmd_handler = commands.Handler.init(fixture.allocator, &fixture.memory.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("GET") });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.err, error.InvalidCommand);
}

test "should handle DELETE command" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    try fixture.memory.?.put("key", .{ .str = @constCast("value") });

    var cmd_handler = commands.Handler.init(fixture.allocator, &fixture.memory.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("DELETE") });
    try command_set.append(.{ .str = @constCast("key") });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result, commands.Handler.Result{ .ok = .{ .sstr = @constCast("OK") } });
    try std.testing.expectEqual(fixture.memory.?.get("key"), error.NotFound);
}

test "should return error.NotFound for non existing during DELETE command" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var cmd_handler = commands.Handler.init(fixture.allocator, &fixture.memory.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("DELETE") });
    try command_set.append(.{ .str = @constCast("key") });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result, commands.Handler.Result{ .err = error.NotFound });
}

test "should DELETE return error.InvalidCommand when missing key" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    try fixture.memory.?.put("key", .{ .str = @constCast("value") });

    var cmd_handler = commands.Handler.init(fixture.allocator, &fixture.memory.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("DELETE") });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.err, error.InvalidCommand);
}

test "should handle FLUSH command" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    try fixture.memory.?.put("key", .{ .str = @constCast("value") });

    var cmd_handler = commands.Handler.init(fixture.allocator, &fixture.memory.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("FLUSH") });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.ok, ZType{ .sstr = @constCast("OK") });
    try std.testing.expectEqual(fixture.memory.?.internal.count(), 0);
}

test "should handle PING command" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    try fixture.memory.?.put("key", .{ .str = @constCast("value") });

    var cmd_handler = commands.Handler.init(fixture.allocator, &fixture.memory.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("PING") });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.ok, ZType{ .sstr = @constCast("PONG") });
}

test "should handle DBSIZE command" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    try fixture.memory.?.put("key", .{ .str = @constCast("value") });

    var cmd_handler = commands.Handler.init(fixture.allocator, &fixture.memory.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("DBSIZE") });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.ok, ZType{ .int = 1 });
}

test "should handle MGET command" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    try fixture.memory.?.put("key", .{ .str = @constCast("value") });
    try fixture.memory.?.put("key2", .{ .str = @constCast("value2") });

    var cmd_handler = commands.Handler.init(fixture.allocator, &fixture.memory.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("MGET") });
    try command_set.append(.{ .str = @constCast("key") });
    try command_set.append(.{ .str = @constCast("key2") });
    try command_set.append(.{ .str = @constCast("key3") });

    var result = cmd_handler.process(&command_set);
    defer result.ok.map.deinit();

    try std.testing.expectEqual(std.meta.activeTag(result.ok), .map);
    try std.testing.expectEqualStrings(result.ok.map.get("key").?.str, @constCast("value"));
    try std.testing.expectEqualStrings(result.ok.map.get("key2").?.str, @constCast("value2"));
    try std.testing.expectEqual(result.ok.map.get("key3").?, ZType{ .null = void{} });
}

test "should handle MSET command" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var cmd_handler = commands.Handler.init(fixture.allocator, &fixture.memory.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("MSET") });
    try command_set.append(.{ .str = @constCast("key") });
    try command_set.append(.{ .str = @constCast("value123") });

    const result = cmd_handler.process(&command_set);

    try std.testing.expectEqual(result.ok, ZType{ .sstr = @constCast("OK") });
    try std.testing.expectEqualStrings((try fixture.memory.?.get("key")).str, command_set.items[2].str);
}

test "should handle MSET return InvalidArgs when empty" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var cmd_handler = commands.Handler.init(fixture.allocator, &fixture.memory.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("MSET") });

    const result = cmd_handler.process(&command_set);

    try std.testing.expectEqual(result.err, error.InvalidArgs);
}

test "should handle MSET and return InvalidArgs when not even" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var cmd_handler = commands.Handler.init(fixture.allocator, &fixture.memory.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("MSET") });
    try command_set.append(.{ .str = @constCast("key") });

    const result = cmd_handler.process(&command_set);

    try std.testing.expectEqual(result.err, error.InvalidArgs);
}

test "should handle MSET and return KeyNotString" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var cmd_handler = commands.Handler.init(fixture.allocator, &fixture.memory.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("MSET") });
    try command_set.append(.{ .sstr = @constCast("key") });
    try command_set.append(.{ .sstr = @constCast("value") });

    const result = cmd_handler.process(&command_set);

    try std.testing.expectEqual(result.err, error.KeyNotString);
}

test "should handle KEYS command" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    try fixture.memory.?.put("key", .{ .str = @constCast("value") });
    try fixture.memory.?.put("key2", .{ .str = @constCast("value2") });

    var cmd_handler = commands.Handler.init(fixture.allocator, &fixture.memory.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("KEYS") });

    var expected = std.ArrayList(ZType).init(fixture.allocator);
    defer expected.deinit();

    try expected.append(.{ .str = @constCast("key2") });
    try expected.append(.{ .str = @constCast("key") });

    var result = cmd_handler.process(&command_set);
    defer result.ok.array.deinit();

    try helper.expectEqualZTypes(result.ok, .{ .array = expected });
}

test "should handle KEYS command no data in storage" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var cmd_handler = commands.Handler.init(fixture.allocator, &fixture.memory.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("KEYS") });

    var expected = std.ArrayList(ZType).init(fixture.allocator);
    defer expected.deinit();

    var result = cmd_handler.process(&command_set);
    defer result.ok.array.deinit();

    try std.testing.expectEqual(result.ok.array.items.len, expected.items.len);
    try helper.expectEqualZTypes(result.ok, .{ .array = expected });
}

test "should handle LASTSAVE command" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    const expected: i64 = fixture.memory.?.last_save;

    var cmd_handler = commands.Handler.init(fixture.allocator, &fixture.memory.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("LASTSAVE") });

    const result = cmd_handler.process(&command_set);
    try helper.expectEqualZTypes(result.ok, .{ .int = expected });
}

test "should SAVE return error.SaveFailure when there is no data" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var cmd_handler = commands.Handler.init(fixture.allocator, &fixture.memory.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();
    try command_set.append(.{ .str = @constCast("SAVE") });

    const result = cmd_handler.process(&command_set);

    try std.testing.expectEqual(result.err, error.SaveFailure);
}

test "should handle SIZEOF command" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var my_map: std.StringHashMap(ZType) = std.StringHashMap(ZType).init(fixture.allocator);
    try my_map.put("123", .{ .int = 50 });
    defer my_map.deinit();

    var my_array: std.ArrayList(ZType) = std.ArrayList(ZType).init(fixture.allocator);
    try my_array.append(.{ .bool = false });
    try my_array.append(.{ .bool = true });
    defer my_array.deinit();

    try fixture.memory.?.put("map-key", .{ .map = my_map });
    try fixture.memory.?.put("array-key", .{ .array = my_array });

    try fixture.memory.?.put("str-key", .{ .str = @constCast("test value") });
    try fixture.memory.?.put("simple-str-key", .{ .sstr = @constCast("test simple value") });

    try fixture.memory.?.put("int-key", .{ .int = 1025 });
    try fixture.memory.?.put("float-key", .{ .float = 809.6 });

    try fixture.memory.?.put("bool-key", .{ .bool = true });
    try fixture.memory.?.put("null-key", .{ .null = undefined });

    var cmd_handler = commands.Handler.init(fixture.allocator, &fixture.memory.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    // Strings

    try command_set.append(.{ .str = @constCast("SIZEOF") });
    try command_set.append(.{ .str = @constCast("str-key") });

    var result = cmd_handler.process(&command_set);
    try helper.expectEqualZTypes(result.ok, .{ .int = 10 });

    try command_set.insert(1, .{ .str = @constCast("simple-str-key") });
    result = cmd_handler.process(&command_set);
    try helper.expectEqualZTypes(result.ok, .{ .int = 17 });

    // Numbers

    try command_set.insert(1, .{ .str = @constCast("float-key") });
    result = cmd_handler.process(&command_set);
    try helper.expectEqualZTypes(result.ok, .{ .int = 8 });

    try command_set.insert(1, .{ .str = @constCast("int-key") });
    result = cmd_handler.process(&command_set);
    try helper.expectEqualZTypes(result.ok, .{ .int = 8 });

    // Bool / Null

    try command_set.insert(1, .{ .str = @constCast("bool-key") });
    result = cmd_handler.process(&command_set);
    try helper.expectEqualZTypes(result.ok, .{ .int = 1 });

    try command_set.insert(1, .{ .str = @constCast("null-key") });
    result = cmd_handler.process(&command_set);
    try helper.expectEqualZTypes(result.ok, .{ .int = 0 });

    // Map / Array

    try command_set.insert(1, .{ .str = @constCast("map-key") });
    result = cmd_handler.process(&command_set);
    try helper.expectEqualZTypes(result.ok, .{ .int = 1 });

    try command_set.insert(1, .{ .str = @constCast("array-key") });
    result = cmd_handler.process(&command_set);
    try helper.expectEqualZTypes(result.ok, .{ .int = 2 });
}

test "should return error.NotFound for non existing during SIZEOF command" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var cmd_handler = commands.Handler.init(fixture.allocator, &fixture.memory.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("SIZEOF") });
    try command_set.append(.{ .str = @constCast("null-key") });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.err, error.NotFound);
}

test "should handle RENAME command" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();
    try fixture.memory.?.put("key", .{ .bool = true });

    var cmd_handler = commands.Handler.init(fixture.allocator, &fixture.memory.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("RENAME") });
    try command_set.append(.{ .str = @constCast("key") });
    try command_set.append(.{ .str = @constCast("key2") });

    const result = cmd_handler.process(&command_set);

    try helper.expectEqualZTypes(result.ok, .{ .str = @constCast("OK") });
    try helper.expectEqualZTypes(try fixture.memory.?.get("key2"), .{ .bool = true });
}

test "should RENAME return error.NotFound" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var cmd_handler = commands.Handler.init(fixture.allocator, &fixture.memory.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("RENAME") });
    try command_set.append(.{ .str = @constCast("key") });
    try command_set.append(.{ .str = @constCast("key2") });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.err, error.NotFound);
}

test "should RENAME return error.InvalidCommand" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var cmd_handler = commands.Handler.init(fixture.allocator, &fixture.memory.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("RENAME") });
    try command_set.append(.{ .str = @constCast("key") });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.err, error.InvalidCommand);
}

test "should RENAME return error.KeyNotString" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var cmd_handler = commands.Handler.init(fixture.allocator, &fixture.memory.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("RENAME") });
    try command_set.append(.{ .int = 50 });
    try command_set.append(.{ .int = 10 });

    var result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.err, error.KeyNotString);

    // To test second key.
    try command_set.insert(1, .{ .str = @constCast("testkey") });
    result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.err, error.KeyNotString);
}
