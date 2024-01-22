const std = @import("std");

const Config = @import("../../src/server/config.zig").Config;
const types = @import("../../src/protocol/types.zig");
const TracingAllocator = @import("../../src/server/tracing.zig").TracingAllocator;
const PersistanceHandler = @import("../../src/server/persistance.zig").PersistanceHandler;
const log = @import("../../src/server/logger.zig");

const MemoryStorage = @import("../../src/server/storage.zig").MemoryStorage;
const helper = @import("../test_helper.zig");

test "should get existing and not get non-existing key" {
    var config = try Config.load(std.testing.allocator, null, null);

    var logger = try log.Logger.init(std.testing.allocator, null);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        null,
    );

    var tracing_allocator = TracingAllocator.init(std.testing.allocator);
    var storage = MemoryStorage.init(
        tracing_allocator.allocator(),
        config,
        &persister,
    );

    defer {
        storage.deinit();
        persister.deinit();
        config.deinit();
    }

    try helper.setup_storage(&storage);

    try std.testing.expectEqual(storage.get("foo"), .{ .int = 42 });
    try std.testing.expectEqual(storage.get("foo2"), .{ .float = 123.45 });
    try std.testing.expectEqual(storage.get("foo3"), .{ .bool = true });
    try std.testing.expectEqual(storage.get("foo4"), .{ .null = void{} });
    // we have to compare values cause it's not same place in memory
    try std.testing.expectEqualStrings((try storage.get("foo5")).sstr, helper.SIMPLE_STRING);
    try std.testing.expectEqualStrings((try storage.get("bar")).str, helper.STRING);

    // array
    var array = try helper.setup_array(std.testing.allocator);
    defer array.deinit();

    try storage.put("foo6", .{ .array = array });

    const getted = try storage.get("foo6");
    try helper.expectEqualZTypes(getted, .{ .array = array });

    // map
    var map = try helper.setup_map(std.testing.allocator);
    defer map.deinit();

    try storage.put("foo7", .{ .map = map });

    const getted_map = try storage.get("foo7");
    try helper.expectEqualZTypes(getted_map, .{ .map = map });

    try std.testing.expectEqual(storage.get("baz"), error.NotFound);
}

test "should delete existing key" {
    var config = try Config.load(std.testing.allocator, null, null);

    var logger = try log.Logger.init(std.testing.allocator, null);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        null,
    );

    var tracing_allocator = TracingAllocator.init(std.testing.allocator);
    var storage = MemoryStorage.init(
        tracing_allocator.allocator(),
        config,
        &persister,
    );

    defer {
        storage.deinit();
        persister.deinit();
        config.deinit();
    }

    var string = "Die meisten Menschen sind nichts als Bauern auf einem Schachbrett, das von einer unbekannten Hand geführt wird.";
    var value: types.ZType = .{ .str = @constCast(string) };

    try storage.put("foo", .{ .int = 42 });
    try storage.put("bar", value);

    try std.testing.expectEqual(storage.delete("foo"), true);
    try std.testing.expectEqual(storage.get("foo"), error.NotFound);
    try std.testing.expectEqualStrings((try storage.get("bar")).str, value.str);
}

test "should not delete non-existing key" {
    var config = try Config.load(std.testing.allocator, null, null);

    var logger = try log.Logger.init(std.testing.allocator, null);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        null,
    );

    var tracing_allocator = TracingAllocator.init(std.testing.allocator);
    var storage = MemoryStorage.init(
        tracing_allocator.allocator(),
        config,
        &persister,
    );

    defer {
        storage.deinit();
        persister.deinit();
        config.deinit();
    }

    try std.testing.expectEqual(storage.delete("foo"), false);
}

test "should flush storage" {
    var config = try Config.load(std.testing.allocator, null, null);

    var logger = try log.Logger.init(std.testing.allocator, null);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        null,
    );

    var tracing_allocator = TracingAllocator.init(std.testing.allocator);
    var storage = MemoryStorage.init(
        tracing_allocator.allocator(),
        config,
        &persister,
    );

    defer {
        storage.deinit();
        persister.deinit();
        config.deinit();
    }

    var string = "Es gibt Momente im Leben, da muss man verstehen, dass die Entscheidungen, die man trifft, nicht nur das eigene Schicksal angehen.";
    var value: types.ZType = .{ .str = @constCast(string) };

    try storage.put("foo", .{ .int = 42 });
    try storage.put("bar", value);

    storage.flush();

    try std.testing.expectEqual(storage.get("foo"), error.NotFound);
    try std.testing.expectEqual(storage.get("bar"), error.NotFound);
}

test "should not store error" {
    var config = try Config.load(std.testing.allocator, null, null);

    var logger = try log.Logger.init(std.testing.allocator, null);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        null,
    );

    var tracing_allocator = TracingAllocator.init(std.testing.allocator);
    var storage = MemoryStorage.init(
        tracing_allocator.allocator(),
        config,
        &persister,
    );

    defer {
        storage.deinit();
        persister.deinit();
        config.deinit();
    }

    const err_value = .{ .err = .{ .message = "random error" } };
    try std.testing.expectEqual(storage.put("test", err_value), error.CantInsertError);
}
