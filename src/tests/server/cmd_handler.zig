const std = @import("std");
const helper = @import("../helper.zig");

const ContextFixture = @import("../fixtures.zig").ContextFixture;
const ZType = @import("../../protocol/types.zig").ZType;
const CMDHandler = @import("../../server/cmd_handler.zig").CMDHandler;

test "should handle SET command" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    fixture.create_memory_storage();

    var cmd_handler = CMDHandler.init(fixture.allocator, &fixture.memory_storage.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("SET") });
    try command_set.append(.{ .str = @constCast("key") });
    try command_set.append(.{ .str = @constCast("value") });

    const result = cmd_handler.process(&command_set);

    try std.testing.expectEqual(result.ok, ZType{ .sstr = @constCast("OK") });
    try std.testing.expectEqualStrings((try fixture.memory_storage.?.get("key")).str, @constCast("value"));
}

test "should SET return error.InvalidCommand when passed 2 args" {
    var fixture = try ContextFixture.init();
    fixture.create_memory_storage();
    defer fixture.deinit();

    var cmd_handler = CMDHandler.init(fixture.allocator, &fixture.memory_storage.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("SET") });
    try command_set.append(.{ .str = @constCast("key") });

    const result = cmd_handler.process(&command_set);

    try std.testing.expectEqual(result.err, error.InvalidCommand);
}

test "should SET return error.InvalidCommand when passed 1 args" {
    var fixture = try ContextFixture.init();
    fixture.create_memory_storage();
    defer fixture.deinit();

    var cmd_handler = CMDHandler.init(fixture.allocator, &fixture.memory_storage.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("SET") });

    const result = cmd_handler.process(&command_set);

    try std.testing.expectEqual(result.err, error.InvalidCommand);
}

test "should handle GET command" {
    var fixture = try ContextFixture.init();
    fixture.create_memory_storage();
    defer fixture.deinit();

    var cmd_handler = CMDHandler.init(fixture.allocator, &fixture.memory_storage.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try fixture.memory_storage.?.put("key", .{ .str = @constCast("value") });

    try command_set.append(.{ .str = @constCast("GET") });
    try command_set.append(.{ .str = @constCast("key") });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqualStrings(result.ok.str, @constCast("value"));
}

test "should SET return error.InvalidCommand when missing key" {
    var fixture = try ContextFixture.init();
    fixture.create_memory_storage();
    defer fixture.deinit();

    try fixture.memory_storage.?.put("key", .{ .str = @constCast("value") });

    var cmd_handler = CMDHandler.init(fixture.allocator, &fixture.memory_storage.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("GET") });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.err, error.InvalidCommand);
}

test "should handle DELETE command" {
    var fixture = try ContextFixture.init();
    fixture.create_memory_storage();
    defer fixture.deinit();

    try fixture.memory_storage.?.put("key", .{ .str = @constCast("value") });

    var cmd_handler = CMDHandler.init(fixture.allocator, &fixture.memory_storage.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("DELETE") });
    try command_set.append(.{ .str = @constCast("key") });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result, CMDHandler.HandlerResult{ .ok = .{ .sstr = @constCast("OK") } });
    try std.testing.expectEqual(fixture.memory_storage.?.get("key"), error.NotFound);
}

test "should return error.NotFound for non existing during DELETE command" {
    var fixture = try ContextFixture.init();
    fixture.create_memory_storage();
    defer fixture.deinit();

    var cmd_handler = CMDHandler.init(fixture.allocator, &fixture.memory_storage.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("DELETE") });
    try command_set.append(.{ .str = @constCast("key") });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result, CMDHandler.HandlerResult{ .err = error.NotFound });
}

test "should DELETE return error.InvalidCommand when missing key" {
    var fixture = try ContextFixture.init();
    fixture.create_memory_storage();
    defer fixture.deinit();

    try fixture.memory_storage.?.put("key", .{ .str = @constCast("value") });

    var cmd_handler = CMDHandler.init(fixture.allocator, &fixture.memory_storage.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("DELETE") });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.err, error.InvalidCommand);
}

test "should handle FLUSH command" {
    var fixture = try ContextFixture.init();
    fixture.create_memory_storage();
    defer fixture.deinit();

    try fixture.memory_storage.?.put("key", .{ .str = @constCast("value") });

    var cmd_handler = CMDHandler.init(fixture.allocator, &fixture.memory_storage.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("FLUSH") });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.ok, ZType{ .sstr = @constCast("OK") });
    try std.testing.expectEqual(fixture.memory_storage.?.internal.count(), 0);
}

test "should handle PING command" {
    var fixture = try ContextFixture.init();
    fixture.create_memory_storage();
    defer fixture.deinit();

    try fixture.memory_storage.?.put("key", .{ .str = @constCast("value") });

    var cmd_handler = CMDHandler.init(fixture.allocator, &fixture.memory_storage.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("PING") });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.ok, ZType{ .sstr = @constCast("PONG") });
}

test "should handle DBSIZE command" {
    var fixture = try ContextFixture.init();
    fixture.create_memory_storage();
    defer fixture.deinit();

    try fixture.memory_storage.?.put("key", .{ .str = @constCast("value") });

    var cmd_handler = CMDHandler.init(fixture.allocator, &fixture.memory_storage.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("DBSIZE") });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.ok, ZType{ .int = 1 });
}

test "should handle MGET command" {
    var fixture = try ContextFixture.init();
    fixture.create_memory_storage();
    defer fixture.deinit();

    try fixture.memory_storage.?.put("key", .{ .str = @constCast("value") });
    try fixture.memory_storage.?.put("key2", .{ .str = @constCast("value2") });

    var cmd_handler = CMDHandler.init(fixture.allocator, &fixture.memory_storage.?, &fixture.logger);

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
    fixture.create_memory_storage();
    defer fixture.deinit();

    var cmd_handler = CMDHandler.init(fixture.allocator, &fixture.memory_storage.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("MSET") });
    try command_set.append(.{ .str = @constCast("key") });
    try command_set.append(.{ .str = @constCast("value123") });

    const result = cmd_handler.process(&command_set);

    try std.testing.expectEqual(result.ok, ZType{ .sstr = @constCast("OK") });
    try std.testing.expectEqualStrings((try fixture.memory_storage.?.get("key")).str, command_set.items[2].str);
}

test "should handle MSET return InvalidArgs when empty" {
    var fixture = try ContextFixture.init();
    fixture.create_memory_storage();
    defer fixture.deinit();

    var cmd_handler = CMDHandler.init(fixture.allocator, &fixture.memory_storage.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("MSET") });

    const result = cmd_handler.process(&command_set);

    try std.testing.expectEqual(result.err, error.InvalidArgs);
}

test "should handle MSET and return InvalidArgs when not even" {
    var fixture = try ContextFixture.init();
    fixture.create_memory_storage();
    defer fixture.deinit();

    var cmd_handler = CMDHandler.init(fixture.allocator, &fixture.memory_storage.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("MSET") });
    try command_set.append(.{ .str = @constCast("key") });

    const result = cmd_handler.process(&command_set);

    try std.testing.expectEqual(result.err, error.InvalidArgs);
}

test "should handle MSET and return KeyNotString" {
    var fixture = try ContextFixture.init();
    fixture.create_memory_storage();
    defer fixture.deinit();

    var cmd_handler = CMDHandler.init(fixture.allocator, &fixture.memory_storage.?, &fixture.logger);

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
    fixture.create_memory_storage();
    defer fixture.deinit();

    try fixture.memory_storage.?.put("key", .{ .str = @constCast("value") });
    try fixture.memory_storage.?.put("key2", .{ .str = @constCast("value2") });

    var cmd_handler = CMDHandler.init(fixture.allocator, &fixture.memory_storage.?, &fixture.logger);

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
    fixture.create_memory_storage();
    defer fixture.deinit();

    var cmd_handler = CMDHandler.init(fixture.allocator, &fixture.memory_storage.?, &fixture.logger);

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
    fixture.create_memory_storage();
    defer fixture.deinit();

    const expected: i64 = fixture.memory_storage.?.last_save;

    var cmd_handler = CMDHandler.init(fixture.allocator, &fixture.memory_storage.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("LASTSAVE") });

    const result = cmd_handler.process(&command_set);
    try helper.expectEqualZTypes(result.ok, .{ .int = expected });
}

test "should SAVE return error.SaveFailure when there is no data" {
    var fixture = try ContextFixture.init();
    fixture.create_memory_storage();
    defer fixture.deinit();

    var cmd_handler = CMDHandler.init(fixture.allocator, &fixture.memory_storage.?, &fixture.logger);

    var command_set = std.ArrayList(ZType).init(fixture.allocator);
    defer command_set.deinit();
    try command_set.append(.{ .str = @constCast("SAVE") });

    const result = cmd_handler.process(&command_set);

    try std.testing.expectEqual(result.err, error.SaveFailure);
}
