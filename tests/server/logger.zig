const std = @import("std");

const Config = @import("../../src/server/config.zig");
const types = @import("../../src/protocol/types.zig");
const TracingAllocator = @import("../../src/server/tracing.zig");
const PersistanceHandler = @import("../../src/server/persistance.zig").PersistanceHandler;
const Logger = @import("../../src/server/logger.zig");

const MemoryStorage = @import("../../src/server/storage.zig");
const helper = @import("../test_helper.zig");

test "test logger debug" {
    std.fs.cwd().deleteTree("logs") catch {};

    var logger = try Logger.init(
        std.testing.allocator,
        null,
        false,
    );
    logger.log(.Debug, "{s}", .{"test"});

    const path: []const u8 = try logger.get_latest_file_path();
    var file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
    logger.allocator.free(path);
    defer file.close();

    const file_size = (try file.stat()).size;
    var buffer = try std.testing.allocator.alloc(u8, file_size);
    const readed = try file.readAll(buffer);
    _ = readed;
    defer std.testing.allocator.free(buffer);

    try std.testing.expectStringEndsWith(buffer, "test\n");
    try std.testing.expectStringStartsWith(buffer, "DEBUG [");

    std.fs.cwd().deleteTree("logs") catch {};
}

test "test logger info" {
    std.fs.cwd().deleteTree("logs") catch {};
    var logger = try Logger.init(std.testing.allocator, null, false);
    logger.log(.Info, "{s}", .{"test"});

    const path: []const u8 = try logger.get_latest_file_path();
    var file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
    logger.allocator.free(path);
    defer file.close();

    const file_size = (try file.stat()).size;
    var buffer = try std.testing.allocator.alloc(u8, file_size);
    const readed = try file.readAll(buffer);
    _ = readed;
    defer std.testing.allocator.free(buffer);

    try std.testing.expectStringEndsWith(buffer, "test\n");
    try std.testing.expectStringStartsWith(buffer, "INFO [");

    std.fs.cwd().deleteTree("logs") catch {};
}

test "test logger warning" {
    std.fs.cwd().deleteTree("logs") catch {};
    var logger = try Logger.init(std.testing.allocator, null, false);
    logger.log(.Warning, "{s}", .{"test"});

    const path: []const u8 = try logger.get_latest_file_path();
    var file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
    logger.allocator.free(path);
    defer file.close();

    const file_size = (try file.stat()).size;
    var buffer = try std.testing.allocator.alloc(u8, file_size);
    const readed = try file.readAll(buffer);
    _ = readed;
    defer std.testing.allocator.free(buffer);

    try std.testing.expectStringEndsWith(buffer, "test\n");
    try std.testing.expectStringStartsWith(buffer, "WARN [");

    std.fs.cwd().deleteTree("logs") catch {};
}

test "test logger error" {
    std.fs.cwd().deleteTree("logs") catch {};

    var logger = try Logger.init(std.testing.allocator, null, false);
    logger.log(.Error, "{s}", .{"test"});

    const path: []const u8 = try logger.get_latest_file_path();
    var file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
    logger.allocator.free(path);
    defer file.close();

    const file_size = (try file.stat()).size;
    var buffer = try std.testing.allocator.alloc(u8, file_size);
    const readed = try file.readAll(buffer);
    _ = readed;
    defer std.testing.allocator.free(buffer);

    try std.testing.expectStringEndsWith(buffer, "test\n");
    try std.testing.expectStringStartsWith(buffer, "ERROR [");

    std.fs.cwd().deleteTree("logs") catch {};
}

// Github CI can't handle that :(
// test "test logger should create a second file" {
//     std.fs.cwd().deleteTree("logs") catch {};

//     var logger = try Logger.init(std.testing.allocator, null, false);
//     const init_latest_path: []const u8 = try logger.get_latest_file_path();
//     defer std.testing.allocator.free(init_latest_path);

//     const log_text: []const u8 = "testtesttesttesttesttesttesttesttesttest" ** 5;
//     const times: usize = 30_100_000 / (38 + log_text.len); // 38 is the log base length.

//     for (1..times) |a| {
//         _ = a;
//         logger.log(Logger.LogLevel.Error, log_text, .{});
//     }
//     const latest_path: []const u8 = try logger.get_latest_file_path();
//     defer std.testing.allocator.free(latest_path);

//     std.fs.cwd().deleteTree("logs") catch {};
//     if (std.mem.eql(u8, init_latest_path, latest_path)) return error.TestNotExpectedEqual;
// }
