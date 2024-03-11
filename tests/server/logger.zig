const std = @import("std");

const Config = @import("../../src/server/config.zig");
const types = @import("../../src/protocol/types.zig");
const TracingAllocator = @import("../../src/server/tracing.zig");
const PersistanceHandler = @import("../../src/server/persistance.zig").PersistanceHandler;
const Logger = @import("../../src/server/logger.zig");

const MemoryStorage = @import("../../src/server/storage.zig");
const helper = @import("../test_helper.zig");

test "test logger debug" {
    std.fs.cwd().deleteTree("log") catch {};
    var logger = try Logger.init(
        std.testing.allocator,
        null,
        false,
    );
    logger.log(.Debug, "{s}", .{"test"});

    var file = try std.fs.cwd().openFile(Logger.DEFAULT_PATH, .{ .mode = .read_only });
    defer file.close();

    const file_size = (try file.stat()).size;
    var buffer = try std.testing.allocator.alloc(u8, file_size);
    const readed = try file.readAll(buffer);
    _ = readed;
    defer std.testing.allocator.free(buffer);

    try std.testing.expectStringEndsWith(buffer, "test\n");
    try std.testing.expectStringStartsWith(buffer, "DEBUG [");

    std.fs.cwd().deleteTree("log") catch {};
}

test "test logger info" {
    std.fs.cwd().deleteTree("log") catch {};
    var logger = try Logger.init(std.testing.allocator, null, false);
    logger.log(.Info, "{s}", .{"test"});

    var file = try std.fs.cwd().openFile(Logger.DEFAULT_PATH, .{ .mode = .read_only });
    defer file.close();

    const file_size = (try file.stat()).size;
    var buffer = try std.testing.allocator.alloc(u8, file_size);
    const readed = try file.readAll(buffer);
    _ = readed;
    defer std.testing.allocator.free(buffer);

    try std.testing.expectStringEndsWith(buffer, "test\n");
    try std.testing.expectStringStartsWith(buffer, "INFO [");

    std.fs.cwd().deleteTree("log") catch {};
}

test "test logger warning" {
    std.fs.cwd().deleteTree("log") catch {};
    var logger = try Logger.init(std.testing.allocator, null, false);
    logger.log(.Warning, "{s}", .{"test"});

    var file = try std.fs.cwd().openFile(Logger.DEFAULT_PATH, .{ .mode = .read_only });
    defer file.close();

    const file_size = (try file.stat()).size;
    var buffer = try std.testing.allocator.alloc(u8, file_size);
    const readed = try file.readAll(buffer);
    _ = readed;
    defer std.testing.allocator.free(buffer);

    try std.testing.expectStringEndsWith(buffer, "test\n");
    try std.testing.expectStringStartsWith(buffer, "WARN [");

    std.fs.cwd().deleteTree("log") catch {};
}

test "test logger error" {
    std.fs.cwd().deleteTree("log") catch {};
    var logger = try Logger.init(std.testing.allocator, null, false);
    logger.log(.Error, "{s}", .{"test"});

    var file = try std.fs.cwd().openFile(Logger.DEFAULT_PATH, .{ .mode = .read_only });
    defer file.close();

    const file_size = (try file.stat()).size;
    var buffer = try std.testing.allocator.alloc(u8, file_size);
    const readed = try file.readAll(buffer);
    _ = readed;
    defer std.testing.allocator.free(buffer);

    try std.testing.expectStringEndsWith(buffer, "test\n");
    try std.testing.expectStringStartsWith(buffer, "ERROR [");

    std.fs.cwd().deleteTree("log") catch {};
}
