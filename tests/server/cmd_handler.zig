const std = @import("std");

const Config = @import("../../src/server/config.zig");
const ZType = @import("../../src/protocol/types.zig").ZType;
const TracingAllocator = @import("../../src/server/tracing.zig");
const PersistanceHandler = @import("../../src/server/persistance.zig").PersistanceHandler;
const CMDHandler = @import("../../src/server/cmd_handler.zig").CMDHandler;
const Logger = @import("../../src/server/logger.zig");

const MemoryStorage = @import("../../src/server/storage.zig");
const helper = @import("../test_helper.zig");

test "should handle SET command" {
    const config = try Config.load(std.testing.allocator, null, null);
    var tracing_allocator = TracingAllocator.init(std.testing.allocator);

    var logger = try Logger.init(std.testing.allocator, null, false);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        null,
    );

    defer persister.deinit();

    var mstorage = MemoryStorage.init(tracing_allocator.allocator(), config, &persister);
    defer mstorage.deinit();

    var cmd_handler = CMDHandler.init(std.testing.allocator, &mstorage, &logger);

    var command_set = std.ArrayList(ZType).init(std.testing.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("SET") });
    try command_set.append(.{ .str = @constCast("key") });
    try command_set.append(.{ .str = @constCast("value") });

    const result = cmd_handler.process(&command_set);

    try std.testing.expectEqual(result.ok, .{ .sstr = @constCast("OK") });
    try std.testing.expectEqualStrings((try mstorage.get("key")).str, @constCast("value"));
}

test "should SET return error.InvalidCommand when passed 2 args" {
    const config = try Config.load(std.testing.allocator, null, null);
    var tracing_allocator = TracingAllocator.init(std.testing.allocator);

    var logger = try Logger.init(std.testing.allocator, null, false);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        null,
    );

    defer persister.deinit();

    var mstorage = MemoryStorage.init(tracing_allocator.allocator(), config, &persister);
    defer mstorage.deinit();

    var cmd_handler = CMDHandler.init(std.testing.allocator, &mstorage, &logger);

    var command_set = std.ArrayList(ZType).init(std.testing.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("SET") });
    try command_set.append(.{ .str = @constCast("key") });

    const result = cmd_handler.process(&command_set);

    try std.testing.expectEqual(result.err, error.InvalidCommand);
}

test "should SET return error.InvalidCommand when passed 1 args" {
    const config = try Config.load(std.testing.allocator, null, null);
    var tracing_allocator = TracingAllocator.init(std.testing.allocator);

    var logger = try Logger.init(std.testing.allocator, null, false);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        null,
    );

    defer persister.deinit();

    var mstorage = MemoryStorage.init(tracing_allocator.allocator(), config, &persister);
    defer mstorage.deinit();

    var cmd_handler = CMDHandler.init(std.testing.allocator, &mstorage, &logger);

    var command_set = std.ArrayList(ZType).init(std.testing.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("SET") });

    const result = cmd_handler.process(&command_set);

    try std.testing.expectEqual(result.err, error.InvalidCommand);
}

test "should handle GET command" {
    const config = try Config.load(std.testing.allocator, null, null);
    var tracing_allocator = TracingAllocator.init(std.testing.allocator);

    var logger = try Logger.init(std.testing.allocator, null, false);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        null,
    );

    defer persister.deinit();

    var mstorage = MemoryStorage.init(tracing_allocator.allocator(), config, &persister);
    defer mstorage.deinit();

    try mstorage.put("key", .{ .str = @constCast("value") });

    var cmd_handler = CMDHandler.init(std.testing.allocator, &mstorage, &logger);

    var command_set = std.ArrayList(ZType).init(std.testing.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("GET") });
    try command_set.append(.{ .str = @constCast("key") });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqualStrings(result.ok.str, @constCast("value"));
}

test "should SET return error.InvalidCommand when missing key" {
    const config = try Config.load(std.testing.allocator, null, null);
    var tracing_allocator = TracingAllocator.init(std.testing.allocator);

    var logger = try Logger.init(std.testing.allocator, null, false);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        null,
    );

    defer persister.deinit();

    var mstorage = MemoryStorage.init(tracing_allocator.allocator(), config, &persister);
    defer mstorage.deinit();

    try mstorage.put("key", .{ .str = @constCast("value") });

    var cmd_handler = CMDHandler.init(std.testing.allocator, &mstorage, &logger);

    var command_set = std.ArrayList(ZType).init(std.testing.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("GET") });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.err, error.InvalidCommand);
}

test "should handle DELETE command" {
    const config = try Config.load(std.testing.allocator, null, null);
    var tracing_allocator = TracingAllocator.init(std.testing.allocator);

    var logger = try Logger.init(std.testing.allocator, null, false);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        null,
    );

    defer persister.deinit();

    var mstorage = MemoryStorage.init(tracing_allocator.allocator(), config, &persister);
    defer mstorage.deinit();

    try mstorage.put("key", .{ .str = @constCast("value") });
    try std.testing.expectEqualStrings((try mstorage.get("key")).str, @constCast("value"));

    var cmd_handler = CMDHandler.init(std.testing.allocator, &mstorage, &logger);

    var command_set = std.ArrayList(ZType).init(std.testing.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("DELETE") });
    try command_set.append(.{ .str = @constCast("key") });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result, .{ .ok = .{ .sstr = @constCast("OK") } });
    try std.testing.expectEqual(mstorage.get("key"), error.NotFound);
}

test "should return error.NotFound for non existing during DELETE command" {
    const config = try Config.load(std.testing.allocator, null, null);
    var tracing_allocator = TracingAllocator.init(std.testing.allocator);

    var logger = try Logger.init(std.testing.allocator, null, false);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        null,
    );

    defer persister.deinit();

    var mstorage = MemoryStorage.init(tracing_allocator.allocator(), config, &persister);
    defer mstorage.deinit();

    var cmd_handler = CMDHandler.init(std.testing.allocator, &mstorage, &logger);

    var command_set = std.ArrayList(ZType).init(std.testing.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("DELETE") });
    try command_set.append(.{ .str = @constCast("key") });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result, .{ .err = error.NotFound });
}

test "should DELETE return error.InvalidCommand when missing key" {
    const config = try Config.load(std.testing.allocator, null, null);
    var tracing_allocator = TracingAllocator.init(std.testing.allocator);

    var logger = try Logger.init(std.testing.allocator, null, false);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        null,
    );

    defer persister.deinit();

    var mstorage = MemoryStorage.init(tracing_allocator.allocator(), config, &persister);
    defer mstorage.deinit();

    try mstorage.put("key", .{ .str = @constCast("value") });
    try std.testing.expectEqualStrings((try mstorage.get("key")).str, @constCast("value"));

    var cmd_handler = CMDHandler.init(std.testing.allocator, &mstorage, &logger);

    var command_set = std.ArrayList(ZType).init(std.testing.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("DELETE") });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.err, error.InvalidCommand);
}

test "should handle FLUSH command" {
    const config = try Config.load(std.testing.allocator, null, null);
    var tracing_allocator = TracingAllocator.init(std.testing.allocator);

    var logger = try Logger.init(std.testing.allocator, null, false);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        null,
    );

    defer persister.deinit();

    var mstorage = MemoryStorage.init(tracing_allocator.allocator(), config, &persister);
    defer mstorage.deinit();

    try mstorage.put("key", .{ .str = @constCast("value") });
    try mstorage.put("key2", .{ .str = @constCast("value2") });

    var cmd_handler = CMDHandler.init(std.testing.allocator, &mstorage, &logger);

    var command_set = std.ArrayList(ZType).init(std.testing.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("FLUSH") });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.ok, .{ .sstr = @constCast("OK") });
    try std.testing.expectEqual(mstorage.internal.count(), 0);
}

test "should handle PING command" {
    const config = try Config.load(std.testing.allocator, null, null);
    var tracing_allocator = TracingAllocator.init(std.testing.allocator);

    var logger = try Logger.init(std.testing.allocator, null, false);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        null,
    );

    defer persister.deinit();

    var mstorage = MemoryStorage.init(tracing_allocator.allocator(), config, &persister);
    defer mstorage.deinit();

    try mstorage.put("key", .{ .str = @constCast("value") });
    try mstorage.put("key2", .{ .str = @constCast("value2") });

    var cmd_handler = CMDHandler.init(std.testing.allocator, &mstorage, &logger);

    var command_set = std.ArrayList(ZType).init(std.testing.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("PING") });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.ok, .{ .sstr = @constCast("PONG") });
}

test "should handle DBSIZE command" {
    const config = try Config.load(std.testing.allocator, null, null);
    var tracing_allocator = TracingAllocator.init(std.testing.allocator);

    var logger = try Logger.init(std.testing.allocator, null, false);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        null,
    );

    defer persister.deinit();

    var mstorage = MemoryStorage.init(tracing_allocator.allocator(), config, &persister);
    defer mstorage.deinit();

    try mstorage.put("key", .{ .str = @constCast("value") });
    try mstorage.put("key2", .{ .str = @constCast("value2") });

    var cmd_handler = CMDHandler.init(std.testing.allocator, &mstorage, &logger);

    var command_set = std.ArrayList(ZType).init(std.testing.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("DBSIZE") });

    const result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.ok, .{ .int = 2 });
}

test "should handle MGET command" {
    const config = try Config.load(std.testing.allocator, null, null);
    var tracing_allocator = TracingAllocator.init(std.testing.allocator);

    var logger = try Logger.init(std.testing.allocator, null, false);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        null,
    );

    defer persister.deinit();

    var mstorage = MemoryStorage.init(tracing_allocator.allocator(), config, &persister);
    defer mstorage.deinit();

    try mstorage.put("key", .{ .str = @constCast("value") });
    try mstorage.put("key2", .{ .str = @constCast("value2") });

    var cmd_handler = CMDHandler.init(std.testing.allocator, &mstorage, &logger);

    var command_set = std.ArrayList(ZType).init(std.testing.allocator);
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
    try std.testing.expectEqual(result.ok.map.get("key3").?.null, .{ .null = void{} });
}

test "should handle MSET command" {
    const config = try Config.load(std.testing.allocator, null, null);
    var tracing_allocator = TracingAllocator.init(std.testing.allocator);

    var logger = try Logger.init(std.testing.allocator, null, false);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        null,
    );

    defer persister.deinit();

    var mstorage = MemoryStorage.init(tracing_allocator.allocator(), config, &persister);
    defer mstorage.deinit();

    var cmd_handler = CMDHandler.init(std.testing.allocator, &mstorage, &logger);

    var command_set = std.ArrayList(ZType).init(std.testing.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("MSET") });
    try command_set.append(.{ .str = @constCast("key") });
    try command_set.append(.{ .str = @constCast("value123") });

    const result = cmd_handler.process(&command_set);

    try std.testing.expectEqual(result.ok, .{ .sstr = @constCast("OK") });
    try std.testing.expectEqualStrings((try mstorage.get("key")).str, command_set.items[2].str);
}

test "should handle MSET return InvalidArgs when empty" {
    const config = try Config.load(std.testing.allocator, null, null);
    var tracing_allocator = TracingAllocator.init(std.testing.allocator);

    var logger = try Logger.init(std.testing.allocator, null, false);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        null,
    );

    defer persister.deinit();

    var mstorage = MemoryStorage.init(tracing_allocator.allocator(), config, &persister);
    defer mstorage.deinit();

    var cmd_handler = CMDHandler.init(std.testing.allocator, &mstorage, &logger);

    var command_set = std.ArrayList(ZType).init(std.testing.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("MSET") });

    const result = cmd_handler.process(&command_set);

    try std.testing.expectEqual(result.err, error.InvalidArgs);
}

test "should handle MSET and return InvalidArgs when not even" {
    const config = try Config.load(std.testing.allocator, null, null);
    var tracing_allocator = TracingAllocator.init(std.testing.allocator);

    var logger = try Logger.init(std.testing.allocator, null, false);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        null,
    );

    defer persister.deinit();

    var mstorage = MemoryStorage.init(tracing_allocator.allocator(), config, &persister);
    defer mstorage.deinit();

    var cmd_handler = CMDHandler.init(std.testing.allocator, &mstorage, &logger);

    var command_set = std.ArrayList(ZType).init(std.testing.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("MSET") });
    try command_set.append(.{ .str = @constCast("key") });

    const result = cmd_handler.process(&command_set);

    try std.testing.expectEqual(result.err, error.InvalidArgs);
}

test "should handle MSET and return KeyNotString" {
    const config = try Config.load(std.testing.allocator, null, null);
    var tracing_allocator = TracingAllocator.init(std.testing.allocator);

    var logger = try Logger.init(std.testing.allocator, null, false);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        null,
    );

    defer persister.deinit();

    var mstorage = MemoryStorage.init(tracing_allocator.allocator(), config, &persister);
    defer mstorage.deinit();

    var cmd_handler = CMDHandler.init(std.testing.allocator, &mstorage, &logger);

    var command_set = std.ArrayList(ZType).init(std.testing.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("MSET") });
    try command_set.append(.{ .sstr = @constCast("key") });
    try command_set.append(.{ .sstr = @constCast("value") });

    const result = cmd_handler.process(&command_set);

    try std.testing.expectEqual(result.err, error.KeyNotString);
}

test "should handle KEYS command" {
    const config = try Config.load(std.testing.allocator, null, null);
    var tracing_allocator = TracingAllocator.init(std.testing.allocator);

    var logger = try Logger.init(std.testing.allocator, null, false);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        null,
    );

    defer persister.deinit();

    var mstorage = MemoryStorage.init(tracing_allocator.allocator(), config, &persister);
    defer mstorage.deinit();

    try mstorage.put("key", .{ .str = @constCast("value") });
    try mstorage.put("key2", .{ .str = @constCast("value2") });

    var cmd_handler = CMDHandler.init(std.testing.allocator, &mstorage, &logger);

    var command_set = std.ArrayList(ZType).init(std.testing.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("KEYS") });

    var expected = std.ArrayList(ZType).init(std.testing.allocator);
    defer expected.deinit();

    try expected.append(.{ .str = @constCast("key") });
    try expected.append(.{ .str = @constCast("key2") });

    var result = cmd_handler.process(&command_set);
    defer result.ok.array.deinit();

    try helper.expectEqualZTypes(result.ok, .{ .array = expected });
}

test "should handle KEYS command no data in storage" {
    const config = try Config.load(std.testing.allocator, null, null);
    var tracing_allocator = TracingAllocator.init(std.testing.allocator);

    var logger = try Logger.init(std.testing.allocator, null, false);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        null,
    );

    defer persister.deinit();

    var mstorage = MemoryStorage.init(tracing_allocator.allocator(), config, &persister);
    defer mstorage.deinit();

    var cmd_handler = CMDHandler.init(std.testing.allocator, &mstorage, &logger);

    var command_set = std.ArrayList(ZType).init(std.testing.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("KEYS") });

    var expected = std.ArrayList(ZType).init(std.testing.allocator);
    defer expected.deinit();

    var result = cmd_handler.process(&command_set);
    defer result.ok.array.deinit();

    try std.testing.expectEqual(result.ok.array.items.len, expected.items.len);
    try helper.expectEqualZTypes(result.ok, .{ .array = expected });
}

test "should handle LASTSAVE command" {
    const config = try Config.load(std.testing.allocator, null, null);
    var tracing_allocator = TracingAllocator.init(std.testing.allocator);

    var logger = try Logger.init(std.testing.allocator, null, false);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        null,
    );

    defer persister.deinit();

    var mstorage = MemoryStorage.init(tracing_allocator.allocator(), config, &persister);
    defer mstorage.deinit();
    const expected: i64 = mstorage.last_save;

    var cmd_handler = CMDHandler.init(std.testing.allocator, &mstorage, &logger);

    var command_set = std.ArrayList(ZType).init(std.testing.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("LASTSAVE") });

    const result = cmd_handler.process(&command_set);
    try helper.expectEqualZTypes(result.ok, .{ .int = expected });
}

test "should SAVE return error.SaveFailure when there is no data" {
    const config = try Config.load(std.testing.allocator, null, null);
    var tracing_allocator = TracingAllocator.init(std.testing.allocator);

    var logger = try Logger.init(std.testing.allocator, null, false);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        null,
    );

    defer persister.deinit();

    var mstorage = MemoryStorage.init(tracing_allocator.allocator(), config, &persister);
    defer mstorage.deinit();

    var cmd_handler = CMDHandler.init(std.testing.allocator, &mstorage, &logger);

    var command_set = std.ArrayList(ZType).init(std.testing.allocator);
    defer command_set.deinit();
    try command_set.append(.{ .str = @constCast("SAVE") });

    const result = cmd_handler.process(&command_set);

    try std.testing.expectEqual(result.err, error.SaveFailure);
}
