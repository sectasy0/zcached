const std = @import("std");

const Config = @import("../../src/server/config.zig");
const types = @import("../../src/protocol/types.zig");
const TracingAllocator = @import("../../src/server/tracing.zig");
const PersistanceHandler = @import("../../src/server/persistance.zig").PersistanceHandler;
const Logger = @import("../../src/server/logger.zig");

const MemoryStorage = @import("../../src/server/storage.zig");
const helper = @import("../test_helper.zig");

test "should load" {
    std.fs.cwd().makePath("./tmp/persist") catch {};
    std.fs.cwd().deleteFile("./tmp/persist/dump_123.zcpf") catch {};

    var config = try Config.load(std.testing.allocator, null, null);
    defer config.deinit();

    const logger = try Logger.init(std.testing.allocator, null, false);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        "./tmp/persist/",
    );
    defer persister.deinit();

    var tracing_allocator = TracingAllocator.init(std.testing.allocator);
    var storage = MemoryStorage.init(tracing_allocator.allocator(), config, &persister);
    defer storage.deinit();

    try std.testing.expectEqual(storage.internal.count(), 0);

    const file_content = "zcpf%4\r\n$5\r\ntest2\r\n$8\r\ntesttest\r\n$5\r\ntest1\r\n$8\r\ntesttest\r\n$5\r\ntest3\r\n$8\r\ntesttest\r\n$5\r\ntest4\r\n$8\r\ntesttest\r\n";
    const file = try std.fs.cwd().createFile("./tmp/persist/dump_123.zcpf", .{});
    try file.writeAll(file_content);
    defer file.close();

    try persister.load(&storage);

    try std.testing.expectEqual(storage.internal.count(), 4);

    std.fs.cwd().deleteFile("./tmp/persist/dump_123.zcpf") catch {};
    std.fs.cwd().deleteDir("./tmp/persist") catch {};
}

test "should not load without header" {
    std.fs.cwd().makePath("./tmp/persist") catch {};
    var config = try Config.load(std.testing.allocator, null, null);
    defer config.deinit();

    const logger = try Logger.init(std.testing.allocator, null, false);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        "./tmp/persist/without_header/",
    );
    defer persister.deinit();

    var tracing_allocator = TracingAllocator.init(std.testing.allocator);
    var storage = MemoryStorage.init(tracing_allocator.allocator(), config, &persister);
    defer storage.deinit();

    std.fs.cwd().makeDir("./tmp/persist/without_header") catch {};

    try std.testing.expectEqual(storage.internal.count(), 0);

    const file_content = "%4\r\n$5\r\ntest2\r\n$8\r\ntesttest\r\n$5\r\ntest1\r\n$8\r\ntesttest\r\n$5\r\ntest3\r\n$8\r\ntesttest\r\n$5\r\ntest4\r\n$8\r\ntesttest";
    const file = try std.fs.cwd().createFile("./tmp/persist/without_header/dump_123.zcpf", .{});
    try file.writeAll(file_content);
    defer file.close();

    try std.testing.expectEqual(persister.load(&storage), error.InvalidFile);

    std.fs.cwd().deleteFile("./tmp/persist/without_header/dump_123.zcpf") catch {};
    std.fs.cwd().deleteDir("./tmp/persist") catch {};
}

test "should not load invalid ext" {
    std.fs.cwd().makePath("./tmp/persist") catch {};

    var config = try Config.load(std.testing.allocator, null, null);
    defer config.deinit();

    const logger = try Logger.init(std.testing.allocator, null, false);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        "./tmp/persist/invalid_ext/",
    );
    defer persister.deinit();

    var tracing_allocator = TracingAllocator.init(std.testing.allocator);
    var storage = MemoryStorage.init(tracing_allocator.allocator(), config, &persister);
    defer storage.deinit();

    std.fs.cwd().makeDir("./tmp/persist/invalid_ext") catch {};

    try std.testing.expectEqual(storage.internal.count(), 0);

    const file_content = "%4\r\n$5\r\ntest2\r\n$8\r\ntesttest\r\n$5\r\ntest1\r\n$8\r\ntesttest\r\n$5\r\ntest3\r\n$8\r\ntesttest\r\n$5\r\ntest4\r\n$8\r\ntesttest";
    const file = try std.fs.cwd().createFile("./tmp/persist/invalid_ext/dump_latest_123.asdf", .{});
    try file.writeAll(file_content);
    defer file.close();

    try std.testing.expectEqual(persister.load(&storage), error.InvalidFile);

    std.fs.cwd().deleteFile("./tmp/persist/invalid_ext/dump_123.asdf") catch {};
    std.fs.cwd().deleteDir("./tmp/persist") catch {};
}

test "should not load corrupted file" {
    std.fs.cwd().makePath("./tmp/persist") catch {};

    var config = try Config.load(std.testing.allocator, null, null);
    defer config.deinit();

    const logger = try Logger.init(std.testing.allocator, null, false);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        "./tmp/persist/corrupted/",
    );
    defer persister.deinit();

    var tracing_allocator = TracingAllocator.init(std.testing.allocator);
    var storage = MemoryStorage.init(tracing_allocator.allocator(), config, &persister);
    defer storage.deinit();

    std.fs.cwd().makeDir("./tmp/persist/corrupted") catch {};

    try std.testing.expectEqual(storage.internal.count(), 0);

    const file_content = "%4\r\n$5test2\r\n$4\r\ntesttest\r\n$5\r\ntest1\r\n$8\r\ntesttest\r\n$5\r\ntest3\r\n$8\r\ntesttest\r\n$5\r\ntest4\r\n$8\r\ntesttest";
    const file = try std.fs.cwd().createFile("./tmp/persist/corrupted/dump_123.asdf", .{});
    try file.writeAll(file_content);
    defer file.close();

    try std.testing.expectEqual(persister.load(&storage), error.InvalidFile);

    std.fs.cwd().deleteFile("./tmp/persist/corrupted/dump_123.asdf") catch {};
    std.fs.cwd().deleteDir("./tmp/persist") catch {};
}

test "should save" {
    std.fs.cwd().makePath("./tmp/persist") catch {};

    var config = try Config.load(std.testing.allocator, null, null);
    defer config.deinit();

    const logger = try Logger.init(std.testing.allocator, null, false);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        null,
    );

    defer persister.deinit();

    var tracing_allocator = TracingAllocator.init(std.testing.allocator);
    var storage = MemoryStorage.init(tracing_allocator.allocator(), config, &persister);
    defer storage.deinit();

    try storage.put("test1", .{ .str = @constCast("testtest") });
    try storage.put("test2", .{ .str = @constCast("testtest") });
    try storage.put("test3", .{ .str = @constCast("testtest") });
    try storage.put("test4", .{ .str = @constCast("testtest") });

    const result = try persister.save(&storage);

    try std.testing.expectEqual(result, 108);

    std.fs.cwd().deleteDir("./tmp/persist") catch {};
}
