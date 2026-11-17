const std = @import("std");
const helper = @import("../helper.zig");

const fixtures = @import("../fixtures.zig");
const ContextFixture = fixtures.ContextFixture;

const ZType = @import("../../protocol/types.zig").ZType;
const sets = @import("../../protocol/types.zig").sets;
const commands = @import("../../server/processing/commands.zig");

// Confirms SET returns OK and stores the supplied value.
test "should handle SET command" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var cmd_handler = commands.Handler.init(fixture.allocator, fixture.context());

    var command_set = std.array_list.Managed(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = "SET" });
    try command_set.append(.{ .str = "key" });
    try command_set.append(.{ .str = "value" });

    const result = cmd_handler.process(&command_set);

    try std.testing.expectEqual(result.ok, ZType{ .sstr = "OK" });
    try std.testing.expectEqualStrings((try fixture.memory.?.get("key")).str, "value");
}

// Checks SET rejects a missing value.
test "should SET return error.InvalidCommand when passed 2 args" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var cmd_handler = commands.Handler.init(fixture.allocator, fixture.context());

    var command_set = std.array_list.Managed(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = "SET" });
    try command_set.append(.{ .str = "key" });

    const result = cmd_handler.process(&command_set);

    try std.testing.expectEqual(result.err, error.InvalidCommand);
}

// Checks SET rejects a command with no key or value.
test "should SET return error.InvalidCommand when passed 1 args" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var cmd_handler = commands.Handler.init(fixture.allocator, fixture.context());

    var command_set = std.array_list.Managed(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = "SET" });

    const result = cmd_handler.process(&command_set);

    try std.testing.expectEqual(result.err, error.InvalidCommand);
}

// Confirms GET returns an owned snapshot that remains valid after storage changes.
test "should handle GET command" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var cmd_handler = commands.Handler.init(fixture.allocator, fixture.context());

    var command_set = std.array_list.Managed(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try fixture.memory.?.put("key", .{ .str = "value" });

    try command_set.append(.{ .str = "GET" });
    try command_set.append(.{ .str = "key" });

    var result = cmd_handler.process(&command_set);
    defer cmd_handler.free(&command_set, &result);
    try fixture.memory.?.put("key", .{ .str = "replacement" });
    try std.testing.expect(fixture.memory.?.delete("key"));
    try std.testing.expectEqualStrings(result.ok.str, "value");
}

// Checks GET rejects a request without a key.
test "should SET return error.InvalidCommand when missing key" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    try fixture.memory.?.put("key", .{ .str = "value" });

    var cmd_handler = commands.Handler.init(fixture.allocator, fixture.context());

    var command_set = std.array_list.Managed(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = "GET" });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.err, error.InvalidCommand);
}

// Confirms DELETE removes an existing key and returns OK.
test "should handle DELETE command" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    try fixture.memory.?.put("key", .{ .str = "value" });

    var cmd_handler = commands.Handler.init(fixture.allocator, fixture.context());

    var command_set = std.array_list.Managed(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = "DELETE" });
    try command_set.append(.{ .str = "key" });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result, commands.Handler.Result{ .ok = .{ .sstr = "OK" } });
    try std.testing.expectEqual(fixture.memory.?.get("key"), error.NotFound);
}

// Checks DELETE reports NotFound for an absent key.
test "should return error.NotFound for non existing during DELETE command" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var cmd_handler = commands.Handler.init(fixture.allocator, fixture.context());

    var command_set = std.array_list.Managed(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = "DELETE" });
    try command_set.append(.{ .str = "key" });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result, commands.Handler.Result{ .err = error.NotFound });
}

// Checks DELETE rejects a request without a key.
test "should DELETE return error.InvalidCommand when missing key" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    try fixture.memory.?.put("key", .{ .str = "value" });

    var cmd_handler = commands.Handler.init(fixture.allocator, fixture.context());

    var command_set = std.array_list.Managed(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = "DELETE" });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.err, error.InvalidCommand);
}

// Confirms FLUSH removes every stored entry and returns OK.
test "should handle FLUSH command" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    try fixture.memory.?.put("key", .{ .str = "value" });

    var cmd_handler = commands.Handler.init(fixture.allocator, fixture.context());

    var command_set = std.array_list.Managed(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = "FLUSH" });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.ok, ZType{ .sstr = "OK" });
    try std.testing.expectEqual(fixture.memory.?.internal.count(), 0);
}

// Confirms PING returns the PONG response.
test "should handle PING command" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    try fixture.memory.?.put("key", .{ .str = "value" });

    var cmd_handler = commands.Handler.init(fixture.allocator, fixture.context());

    var command_set = std.array_list.Managed(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = "PING" });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.ok, ZType{ .sstr = "PONG" });
}

// Confirms DBSIZE reports the number of stored keys.
test "should handle DBSIZE command" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    try fixture.memory.?.put("key", .{ .str = "value" });

    var cmd_handler = commands.Handler.init(fixture.allocator, fixture.context());

    var command_set = std.array_list.Managed(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = "DBSIZE" });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.ok, ZType{ .int = 1 });
}

// Checks MGET returns present values and null for a missing key.
test "should handle MGET command" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    try fixture.memory.?.put("key", .{ .str = "value" });
    try fixture.memory.?.put("key2", .{ .str = "value2" });

    var cmd_handler = commands.Handler.init(fixture.allocator, fixture.context());

    var command_set = std.array_list.Managed(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = "MGET" });
    try command_set.append(.{ .str = "key" });
    try command_set.append(.{ .str = "key2" });
    try command_set.append(.{ .str = "key3" });

    var result = cmd_handler.process(&command_set);
    defer cmd_handler.free(&command_set, &result);
    fixture.memory.?.flush();

    try std.testing.expectEqual(std.meta.activeTag(result.ok), .map);
    try std.testing.expectEqualStrings(result.ok.map.get("key").?.str, "value");
    try std.testing.expectEqualStrings(result.ok.map.get("key2").?.str, "value2");
    try std.testing.expectEqual(result.ok.map.get("key3").?, ZType{ .null = {} });
}

// Confirms MSET stores alternating key/value arguments.
test "should handle MSET command" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var cmd_handler = commands.Handler.init(fixture.allocator, fixture.context());

    var command_set = std.array_list.Managed(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = "MSET" });
    try command_set.append(.{ .str = "key" });
    try command_set.append(.{ .str = "value123" });

    const result = cmd_handler.process(&command_set);

    try std.testing.expectEqual(result.ok, ZType{ .sstr = "OK" });
    try std.testing.expectEqualStrings((try fixture.memory.?.get("key")).str, command_set.items[2].str);
}

// Checks MSET requires at least one key/value pair.
test "should handle MSET return InvalidArgs when empty" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var cmd_handler = commands.Handler.init(fixture.allocator, fixture.context());

    var command_set = std.array_list.Managed(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = "MSET" });

    const result = cmd_handler.process(&command_set);

    try std.testing.expectEqual(result.err, error.InvalidArgs);
}

// Checks MSET rejects an unmatched key argument.
test "should handle MSET and return InvalidArgs when not even" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var cmd_handler = commands.Handler.init(fixture.allocator, fixture.context());

    var command_set = std.array_list.Managed(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = "MSET" });
    try command_set.append(.{ .str = "key" });

    const result = cmd_handler.process(&command_set);

    try std.testing.expectEqual(result.err, error.InvalidArgs);
}

// Checks MSET rejects non-string keys.
test "should handle MSET and return KeyNotString" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var cmd_handler = commands.Handler.init(fixture.allocator, fixture.context());

    var command_set = std.array_list.Managed(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = "MSET" });
    try command_set.append(.{ .sstr = "key" });
    try command_set.append(.{ .sstr = "value" });

    const result = cmd_handler.process(&command_set);

    try std.testing.expectEqual(result.err, error.KeyNotString);
}

// Confirms KEYS returns all stored keys in the expected array.
test "should handle KEYS command" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    try fixture.memory.?.put("key", .{ .str = "value" });
    try fixture.memory.?.put("key2", .{ .str = "value2" });

    var cmd_handler = commands.Handler.init(fixture.allocator, fixture.context());

    var command_set = std.array_list.Managed(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = "KEYS" });

    var expected = std.array_list.Managed(ZType).init(fixture.allocator);
    defer expected.deinit();

    try expected.append(.{ .str = "key2" });
    try expected.append(.{ .str = "key" });

    var result = cmd_handler.process(&command_set);
    defer cmd_handler.free(&command_set, &result);
    fixture.memory.?.flush();

    try helper.expectEqualZTypes(result.ok, .{ .array = expected });
}

// Checks KEYS returns an empty array for empty storage.
test "should handle KEYS command no data in storage" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var cmd_handler = commands.Handler.init(fixture.allocator, fixture.context());

    var command_set = std.array_list.Managed(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = "KEYS" });

    var expected = std.array_list.Managed(ZType).init(fixture.allocator);
    defer expected.deinit();

    var result = cmd_handler.process(&command_set);
    defer cmd_handler.free(&command_set, &result);

    try std.testing.expectEqual(result.ok.array.items.len, expected.items.len);
    try helper.expectEqualZTypes(result.ok, .{ .array = expected });
}

// Confirms LASTSAVE exposes the current persistence timestamp.
test "should handle LASTSAVE command" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    const expected: i64 = fixture.memory.?.last_save;

    var cmd_handler = commands.Handler.init(fixture.allocator, fixture.context());

    var command_set = std.array_list.Managed(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = "LASTSAVE" });

    const result = cmd_handler.process(&command_set);
    try helper.expectEqualZTypes(result.ok, .{ .int = expected });
}

// Checks SAVE reports failure when storage is empty.
test "should SAVE return error.SaveFailure when there is no data" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var cmd_handler = commands.Handler.init(fixture.allocator, fixture.context());

    var command_set = std.array_list.Managed(ZType).init(fixture.allocator);
    defer command_set.deinit();
    try command_set.append(.{ .str = "SAVE" });

    const result = cmd_handler.process(&command_set);

    try std.testing.expectEqual(result.err, error.SaveFailure);
}

// Checks SIZEOF reports encoded byte sizes for supported value types.
test "should handle SIZEOF command" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var my_map = std.StringHashMap(ZType).init(fixture.allocator);
    try my_map.put("123", .{ .int = 50 });
    defer my_map.deinit();

    var my_set = sets.Set(ZType).init(fixture.allocator);
    try my_set.insert(.{ .int = 50 });
    defer my_set.deinit();

    var my_uset = sets.SetUnordered(ZType).init(fixture.allocator);
    try my_uset.insert(.{ .int = 50 });
    defer my_uset.deinit();

    var my_array = std.array_list.Managed(ZType).init(fixture.allocator);
    try my_array.append(.{ .bool = false });
    try my_array.append(.{ .bool = true });
    defer my_array.deinit();

    try fixture.memory.?.put("map-key", .{ .map = my_map });
    try fixture.memory.?.put("array-key", .{ .array = my_array });
    try fixture.memory.?.put("set-key", .{ .set = my_set });
    try fixture.memory.?.put("uset-key", .{ .uset = my_uset });

    try fixture.memory.?.put("str-key", .{ .str = "test value" });
    try fixture.memory.?.put("simple-str-key", .{ .sstr = "test simple value" });

    try fixture.memory.?.put("int-key", .{ .int = 1025 });
    try fixture.memory.?.put("float-key", .{ .float = 809.6 });

    try fixture.memory.?.put("bool-key", .{ .bool = true });
    try fixture.memory.?.put("null-key", .{ .null = undefined });

    var cmd_handler = commands.Handler.init(fixture.allocator, fixture.context());

    var command_set = std.array_list.Managed(ZType).init(fixture.allocator);
    defer command_set.deinit();

    // Strings

    try command_set.append(.{ .str = "SIZEOF" });
    try command_set.append(.{ .str = "str-key" });

    var result = cmd_handler.process(&command_set);
    try helper.expectEqualZTypes(result.ok, .{ .int = 10 });

    try command_set.insert(1, .{ .str = "simple-str-key" });
    result = cmd_handler.process(&command_set);
    try helper.expectEqualZTypes(result.ok, .{ .int = 17 });

    // Numbers

    try command_set.insert(1, .{ .str = "float-key" });
    result = cmd_handler.process(&command_set);
    try helper.expectEqualZTypes(result.ok, .{ .int = 8 });

    try command_set.insert(1, .{ .str = "int-key" });
    result = cmd_handler.process(&command_set);
    try helper.expectEqualZTypes(result.ok, .{ .int = 8 });

    // Bool / Null

    try command_set.insert(1, .{ .str = "bool-key" });
    result = cmd_handler.process(&command_set);
    try helper.expectEqualZTypes(result.ok, .{ .int = 1 });

    try command_set.insert(1, .{ .str = "null-key" });
    result = cmd_handler.process(&command_set);
    try helper.expectEqualZTypes(result.ok, .{ .int = 0 });

    // Map / Array

    try command_set.insert(1, .{ .str = "map-key" });
    result = cmd_handler.process(&command_set);
    try helper.expectEqualZTypes(result.ok, .{ .int = 1 });

    try command_set.insert(1, .{ .str = "array-key" });
    result = cmd_handler.process(&command_set);
    try helper.expectEqualZTypes(result.ok, .{ .int = 2 });

    try command_set.insert(1, .{ .str = "set-key" });
    result = cmd_handler.process(&command_set);
    try helper.expectEqualZTypes(result.ok, .{ .int = 1 });

    try command_set.insert(1, .{ .str = "uset-key" });
    result = cmd_handler.process(&command_set);
    try helper.expectEqualZTypes(result.ok, .{ .int = 1 });
}

// Checks SIZEOF reports NotFound for an absent key.
test "should return error.NotFound for non existing during SIZEOF command" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var cmd_handler = commands.Handler.init(fixture.allocator, fixture.context());

    var command_set = std.array_list.Managed(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = "SIZEOF" });
    try command_set.append(.{ .str = "null-key" });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.err, error.NotFound);
}

// Confirms ECHO preserves both string and simple-string response types.
test "should handle ECHO command" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var cmd_handler = commands.Handler.init(fixture.allocator, fixture.context());

    var command_set = std.array_list.Managed(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = "ECHO" });
    try command_set.append(.{ .str = "Hello World!" });

    var result = cmd_handler.process(&command_set);
    try helper.expectEqualZTypes(result.ok, .{ .str = "Hello World!" });

    // Simple string case.
    try command_set.insert(1, .{ .sstr = "Hello Mars!" });
    result = cmd_handler.process(&command_set);
    try helper.expectEqualZTypes(result.ok, .{ .sstr = "Hello Mars!" });
}

// Checks ECHO rejects a non-string argument.
test "should ECHO return error.KeyNotString" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var cmd_handler = commands.Handler.init(fixture.allocator, fixture.context());

    var command_set = std.array_list.Managed(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = "ECHO" });
    try command_set.append(.{ .int = 5 });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.err, error.KeyNotString);
}

// Confirms RENAME moves a value to the destination key.
test "should handle RENAME command" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();
    try fixture.memory.?.put("key", .{ .bool = true });

    var cmd_handler = commands.Handler.init(fixture.allocator, fixture.context());

    var command_set = std.array_list.Managed(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = "RENAME" });
    try command_set.append(.{ .str = "key" });
    try command_set.append(.{ .str = "key2" });

    const result = cmd_handler.process(&command_set);

    try helper.expectEqualZTypes(result.ok, .{ .sstr = "OK" });
    try helper.expectEqualZTypes(try fixture.memory.?.get("key2"), .{ .bool = true });
}

// Checks RENAME reports NotFound when the source key is absent.
test "should RENAME return error.NotFound" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var cmd_handler = commands.Handler.init(fixture.allocator, fixture.context());

    var command_set = std.array_list.Managed(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = "RENAME" });
    try command_set.append(.{ .str = "key" });
    try command_set.append(.{ .str = "key2" });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.err, error.NotFound);
}

// Checks RENAME rejects a missing destination key.
test "should RENAME return error.InvalidCommand" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var cmd_handler = commands.Handler.init(fixture.allocator, fixture.context());

    var command_set = std.array_list.Managed(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = "RENAME" });
    try command_set.append(.{ .str = "key" });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.err, error.InvalidCommand);
}

// Checks RENAME rejects non-string source or destination keys.
test "should RENAME return error.KeyNotString" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var cmd_handler = commands.Handler.init(fixture.allocator, fixture.context());

    var command_set = std.array_list.Managed(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = "RENAME" });
    try command_set.append(.{ .int = 50 });
    try command_set.append(.{ .int = 10 });

    var result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.err, error.KeyNotString);

    // To test second key.
    try command_set.insert(1, .{ .str = "testkey" });
    result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.err, error.KeyNotString);
}

// Confirms COPY creates a destination with the source value.
test "should handle COPY command" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    try fixture.memory.?.put("test", .{ .int = 10 });
    var cmd_handler = commands.Handler.init(fixture.allocator, fixture.context());

    var command_set = std.array_list.Managed(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = "COPY" });
    try command_set.append(.{ .str = "test" });
    try command_set.append(.{ .str = "testcopy" });

    const result = cmd_handler.process(&command_set);
    try helper.expectEqualZTypes(result.ok, .{ .str = "OK" });
    try helper.expectEqualZTypes(try fixture.memory.?.get("testcopy"), .{ .int = 10 });
}

// Checks COPY with REPLACE overwrites an existing destination.
test "should handle COPY command with REPLACE param" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    try fixture.memory.?.put("test", .{ .int = 1 });
    try fixture.memory.?.put("test2", .{ .int = 2 });
    var cmd_handler = commands.Handler.init(fixture.allocator, fixture.context());

    var command_set = std.array_list.Managed(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = "COPY" });
    try command_set.append(.{ .str = "test" });
    try command_set.append(.{ .str = "test2" });
    try command_set.append(.{ .str = "REPLACE" });

    const result = cmd_handler.process(&command_set);
    try helper.expectEqualZTypes(result.ok, .{ .str = "OK" });
    try helper.expectEqualZTypes(try fixture.memory.?.get("test2"), .{ .int = 1 });
}

// Checks COPY rejects a request missing its destination.
test "should COPY return error.InvalidCommand" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var cmd_handler = commands.Handler.init(fixture.allocator, fixture.context());

    var command_set = std.array_list.Managed(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = "COPY" });
    try command_set.append(.{ .str = "test" });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.err, error.InvalidCommand);
}

// Checks COPY rejects non-string source, destination, or modifier arguments.
test "should COPY return error.KeyNotString" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    var cmd_handler = commands.Handler.init(fixture.allocator, fixture.context());

    var command_set = std.array_list.Managed(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = "COPY" });
    try command_set.append(.{ .float = 0.1 });
    try command_set.append(.{ .float = 0.2 });
    try command_set.append(.{ .float = 0.3 });

    for (1..4) |index| {
        // Replace float parameter with a string and see if the next one returns an error.
        const result = cmd_handler.process(&command_set);
        try std.testing.expectEqual(result.err, error.KeyNotString);

        try command_set.insert(index, .{ .str = "strparam" });
    }
}

// Checks COPY without REPLACE rejects an existing destination.
test "should COPY return error.BusyKey" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();
    try fixture.memory.?.put("test", .{ .int = 1 });
    try fixture.memory.?.put("test2", .{ .int = 2 });

    var cmd_handler = commands.Handler.init(fixture.allocator, fixture.context());
    var command_set = std.array_list.Managed(ZType).init(fixture.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = "COPY" });
    try command_set.append(.{ .str = "test" });
    try command_set.append(.{ .str = "test2" });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.err, error.BusyKey);
}
