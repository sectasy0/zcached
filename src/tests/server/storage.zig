const std = @import("std");

const Config = @import("../../server/config.zig");
const types = @import("../../protocol/types.zig");
const TracingAllocator = @import("../../server/tracing.zig");
const PersistanceHandler = @import("../../server/persistance.zig").PersistanceHandler;
const Logger = @import("../../server/logger.zig");

const MemoryStorage = @import("../../server/storage.zig");
const helper = @import("../helper.zig");

test "should get existing and not get non-existing key" {
    var config = try Config.load(std.testing.allocator, null, null);

    const logger = try Logger.init(std.testing.allocator, null, false);

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

    try std.testing.expectEqual(storage.get("foo"), types.ZType{ .int = 42 });
    try std.testing.expectEqual(storage.get("foo2"), types.ZType{ .float = 123.45 });
    try std.testing.expectEqual(storage.get("foo3"), types.ZType{ .bool = true });
    try std.testing.expectEqual(storage.get("foo4"), types.ZType{ .null = void{} });
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

    const logger = try Logger.init(std.testing.allocator, null, false);

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

    const string = "Die meisten Menschen sind nichts als Bauern auf einem Schachbrett, das von einer unbekannten Hand geführt wird.";
    const value: types.ZType = .{ .str = @constCast(string) };

    try storage.put("foo", .{ .int = 42 });
    try storage.put("bar", value);

    try std.testing.expectEqual(storage.delete("foo"), true);
    try std.testing.expectEqual(storage.get("foo"), error.NotFound);
    try std.testing.expectEqualStrings((try storage.get("bar")).str, value.str);
}

test "should not delete non-existing key" {
    var config = try Config.load(std.testing.allocator, null, null);

    const logger = try Logger.init(std.testing.allocator, null, false);

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

    const logger = try Logger.init(std.testing.allocator, null, false);

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

    const string = "Es gibt Momente im Leben, da muss man verstehen, dass die Entscheidungen, die man trifft, nicht nur das eigene Schicksal angehen.";
    const value: types.ZType = .{ .str = @constCast(string) };

    try storage.put("foo", .{ .int = 42 });
    try storage.put("bar", value);

    storage.flush();

    try std.testing.expectEqual(storage.get("foo"), error.NotFound);
    try std.testing.expectEqual(storage.get("bar"), error.NotFound);
}

test "should not store error" {
    var config = try Config.load(std.testing.allocator, null, null);

    const logger = try Logger.init(std.testing.allocator, null, false);

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

test "should return error.MemoryLimitExceeded" {
    var config = try Config.load(std.testing.allocator, null, null);
    defer config.deinit();
    config.maxmemory = 1048576;

    const logger = try Logger.init(std.testing.allocator, null, false);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        null,
    );
    persister.deinit();

    var tracing_allocator = TracingAllocator.init(std.testing.allocator);
    var storage = MemoryStorage.init(
        tracing_allocator.allocator(),
        config,
        &persister,
    );
    defer storage.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const string = "Was wir wissen, ist ein Tropfen, was wir nicht wissen, ein Ozean.";
    const value: types.ZType = .{ .str = @constCast(string) };
    for (0..6554) |i| {
        const key = try std.fmt.allocPrint(arena.allocator(), "key-{d}", .{i});
        try storage.put(key, value);
    }

    try std.testing.expectEqual(storage.put("test key", value), error.MemoryLimitExceeded);
}

test "should not return error.MemoryLimitExceed when max but deleted some" {
    var config = try Config.load(std.testing.allocator, null, null);
    defer config.deinit();
    config.maxmemory = 1048576;

    const logger = try Logger.init(std.testing.allocator, null, false);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        null,
    );
    persister.deinit();

    var tracing_allocator = TracingAllocator.init(std.testing.allocator);
    var storage = MemoryStorage.init(
        tracing_allocator.allocator(),
        config,
        &persister,
    );
    defer storage.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // const utils = @import("../../server/utils.zig");
    // const tracking = utils.ptrCast(TracingAllocator, storage.allocator.ptr);

    const string = "Was wir wissen, ist ein Tropfen, was wir nicht wissen, ein Ozean.";
    const value: types.ZType = .{ .str = @constCast(string) };
    for (0..1) |i| {
        const key = try std.fmt.allocPrint(arena.allocator(), "key-{d}", .{i});
        try storage.put(key, value);
    }

    const result = storage.put("test key", value);

    try std.testing.expectEqual(void{}, result);
}
