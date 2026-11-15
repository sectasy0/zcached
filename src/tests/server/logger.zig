const std = @import("std");
const fs = @import("fs");

const Logger = @import("../../server/logger.zig");

test "test logger debug" {
    fs.cwd().deleteTree("log") catch {};

    var logger = try Logger.init(
        std.testing.allocator,
        null,
        null,
        false,
    );
    defer logger.deinit();
    logger.log(.Debug, "{s}", .{"test"});

    logger.flush();

    var file = try fs.cwd().openFile(Logger.DEFAULT_PATH, .{ .mode = .read_only });
    defer file.close();

    const file_size = (try file.stat()).size;
    const buffer = try std.testing.allocator.alloc(u8, file_size);
    const readed = try file.readAll(buffer);
    _ = readed;
    defer std.testing.allocator.free(buffer);

    try std.testing.expectStringEndsWith(buffer, "test\n");
    try std.testing.expectStringStartsWith(buffer, "DEBUG [");

    fs.cwd().deleteTree("log") catch {};
}

test "test logger info" {
    fs.cwd().deleteTree("log") catch {};
    var logger = try Logger.init(std.testing.allocator, null, null, false);
    defer logger.deinit();

    logger.log(.Info, "{s}", .{"test"});
    logger.flush();

    var file = try fs.cwd().openFile(Logger.DEFAULT_PATH, .{ .mode = .read_only });
    defer file.close();

    const file_size = (try file.stat()).size;
    const buffer = try std.testing.allocator.alloc(u8, file_size);
    const readed = try file.readAll(buffer);
    _ = readed;
    defer std.testing.allocator.free(buffer);

    try std.testing.expectStringEndsWith(buffer, "test\n");
    try std.testing.expectStringStartsWith(buffer, "INFO [");

    fs.cwd().deleteTree("log") catch {};
}

test "test logger warning" {
    fs.cwd().deleteTree("log") catch {};
    var logger = try Logger.init(std.testing.allocator, null, null, false);
    defer logger.deinit();

    logger.log(.Warning, "{s}", .{"test"});
    logger.flush();

    var file = try fs.cwd().openFile(Logger.DEFAULT_PATH, .{ .mode = .read_only });
    defer file.close();

    const file_size = (try file.stat()).size;
    const buffer = try std.testing.allocator.alloc(u8, file_size);
    const readed = try file.readAll(buffer);
    _ = readed;
    defer std.testing.allocator.free(buffer);

    try std.testing.expectStringEndsWith(buffer, "test\n");
    try std.testing.expectStringStartsWith(buffer, "WARN [");

    fs.cwd().deleteTree("log") catch {};
}

test "test logger error" {
    fs.cwd().deleteTree("log") catch {};

    var logger = try Logger.init(std.testing.allocator, null, null, false);
    defer logger.deinit();

    logger.log(.Error, "{s}", .{"test"});
    logger.flush();

    var file = try fs.cwd().openFile(Logger.DEFAULT_PATH, .{ .mode = .read_only });
    defer file.close();

    const file_size = (try file.stat()).size;
    const buffer = try std.testing.allocator.alloc(u8, file_size);
    const readed = try file.readAll(buffer);
    _ = readed;
    defer std.testing.allocator.free(buffer);

    try std.testing.expectStringEndsWith(buffer, "test\n");
    try std.testing.expectStringStartsWith(buffer, "ERROR [");

    fs.cwd().deleteTree("log") catch {};
}

test "auto flush when buffer is full" {
    fs.cwd().deleteTree("log") catch {};

    var logger = try Logger.init(std.testing.allocator, null, null, false);
    defer logger.deinit();

    var output = try std.array_list.Managed(u8).initCapacity(std.testing.allocator, logger.buffer.items.len);
    for (0..logger.buffer.items.len) |i| {
        logger.log(.Debug, "{d}", .{i});

        var buff: [1024]u8 = undefined;
        const data = try std.fmt.bufPrint(&buff, "{d}", .{i});
        try output.appendSlice(data);
    }

    var file = try fs.cwd().openFile(Logger.DEFAULT_PATH, .{ .mode = .read_only });
    defer file.close();

    const file_size = (try file.stat()).size;
    const buffer = try std.testing.allocator.alloc(u8, file_size);
    const readed = try file.readAll(buffer);
    _ = readed;
    defer std.testing.allocator.free(buffer);

    try std.testing.expectStringStartsWith(buffer, output.items);

    fs.cwd().deleteTree("log") catch {};
}
