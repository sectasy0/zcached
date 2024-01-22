const std = @import("std");

const Config = @import("../../src/server/config.zig").Config;
const ZType = @import("../../src/protocol/types.zig").ZType;
const TracingAllocator = @import("../../src/server/tracing.zig").TracingAllocator;
const PersistanceHandler = @import("../../src/server/persistance.zig").PersistanceHandler;
const CMDHandler = @import("../../src/server/cmd_handler.zig").CMDHandler;
const log = @import("../../src/server/logger.zig");

const MemoryStorage = @import("../../src/server/storage.zig").MemoryStorage;
const helper = @import("../test_helper.zig");

test "should handle SET command" {
    const config = try Config.load(std.testing.allocator, null, null);
    var tracing_allocator = TracingAllocator.init(std.testing.allocator);

    var logger = try log.Logger.init(std.testing.allocator, null);

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

    var result = cmd_handler.process(&command_set);

    try std.testing.expectEqual(result.ok, .{ .sstr = @constCast("OK") });
    try std.testing.expectEqualStrings((try mstorage.get("key")).str, @constCast("value"));
}

test "should handle GET command" {
    const config = try Config.load(std.testing.allocator, null, null);
    var tracing_allocator = TracingAllocator.init(std.testing.allocator);

    var logger = try log.Logger.init(std.testing.allocator, null);

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

    var result = cmd_handler.process(&command_set);
    try std.testing.expectEqualStrings(result.ok.str, @constCast("value"));
}

test "should handle DELETE command" {
    const config = try Config.load(std.testing.allocator, null, null);
    var tracing_allocator = TracingAllocator.init(std.testing.allocator);

    var logger = try log.Logger.init(std.testing.allocator, null);

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

    var result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result, .{ .ok = .{ .sstr = @constCast("OK") } });
    try std.testing.expectEqual(mstorage.get("key"), error.NotFound);
}

test "should return error.NotFound for non existing during DELETE command" {
    const config = try Config.load(std.testing.allocator, null, null);
    var tracing_allocator = TracingAllocator.init(std.testing.allocator);

    var logger = try log.Logger.init(std.testing.allocator, null);

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

    var result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result, .{ .err = error.NotFound });
}

test "should handle FLUSH command" {
    const config = try Config.load(std.testing.allocator, null, null);
    var tracing_allocator = TracingAllocator.init(std.testing.allocator);

    var logger = try log.Logger.init(std.testing.allocator, null);

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

    var result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.ok, .{ .null = void{} });
    try std.testing.expectEqual(mstorage.internal.count(), 0);
}

test "should handle PING command" {
    const config = try Config.load(std.testing.allocator, null, null);
    var tracing_allocator = TracingAllocator.init(std.testing.allocator);

    var logger = try log.Logger.init(std.testing.allocator, null);

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

    var result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.ok, .{ .sstr = @constCast("PONG") });
}

test "should handle DBSIZE command" {
    const config = try Config.load(std.testing.allocator, null, null);
    var tracing_allocator = TracingAllocator.init(std.testing.allocator);

    var logger = try log.Logger.init(std.testing.allocator, null);

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

    var result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.ok, .{ .int = 2 });
}
