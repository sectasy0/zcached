const std = @import("std");

const Logger = @import("../../server/logger.zig");

test "test logger debug" {
    std.fs.cwd().deleteTree("log") catch {};

    var logger = try Logger.init(
        std.testing.allocator,
        null,
        null,
        false,
    );
    defer logger.deinit();
    logger.log(.Debug, "{s}", .{"test"});

    logger.flush();

    var file = try std.fs.cwd().openFile(Logger.DEFAULT_PATH, .{ .mode = .read_only });
    defer file.close();

    const file_size = (try file.stat()).size;
    const buffer = try std.testing.allocator.alloc(u8, file_size);
    const readed = try file.readAll(buffer);
    _ = readed;
    defer std.testing.allocator.free(buffer);

    try std.testing.expectStringEndsWith(buffer, "test\n");
    try std.testing.expectStringStartsWith(buffer, "DEBUG [");

    std.fs.cwd().deleteTree("log") catch {};
}

test "test logger info" {
    std.fs.cwd().deleteTree("log") catch {};
    var logger = try Logger.init(std.testing.allocator, null, null, false);
    defer logger.deinit();

    logger.log(.Info, "{s}", .{"test"});
    logger.flush();

    var file = try std.fs.cwd().openFile(Logger.DEFAULT_PATH, .{ .mode = .read_only });
    defer file.close();

    const file_size = (try file.stat()).size;
    const buffer = try std.testing.allocator.alloc(u8, file_size);
    const readed = try file.readAll(buffer);
    _ = readed;
    defer std.testing.allocator.free(buffer);

    try std.testing.expectStringEndsWith(buffer, "test\n");
    try std.testing.expectStringStartsWith(buffer, "INFO [");

    std.fs.cwd().deleteTree("log") catch {};
}

test "test logger warning" {
    std.fs.cwd().deleteTree("log") catch {};
    var logger = try Logger.init(std.testing.allocator, null, null, false);
    defer logger.deinit();

    logger.log(.Warning, "{s}", .{"test"});
    logger.flush();

    var file = try std.fs.cwd().openFile(Logger.DEFAULT_PATH, .{ .mode = .read_only });
    defer file.close();

    const file_size = (try file.stat()).size;
    const buffer = try std.testing.allocator.alloc(u8, file_size);
    const readed = try file.readAll(buffer);
    _ = readed;
    defer std.testing.allocator.free(buffer);

    try std.testing.expectStringEndsWith(buffer, "test\n");
    try std.testing.expectStringStartsWith(buffer, "WARN [");

    std.fs.cwd().deleteTree("log") catch {};
}

test "test logger error" {
    std.fs.cwd().deleteTree("log") catch {};

    var logger = try Logger.init(std.testing.allocator, null, null, false);
    defer logger.deinit();

    logger.log(.Error, "{s}", .{"test"});
    logger.flush();

    var file = try std.fs.cwd().openFile(Logger.DEFAULT_PATH, .{ .mode = .read_only });
    defer file.close();

    const file_size = (try file.stat()).size;
    const buffer = try std.testing.allocator.alloc(u8, file_size);
    const readed = try file.readAll(buffer);
    _ = readed;
    defer std.testing.allocator.free(buffer);

    try std.testing.expectStringEndsWith(buffer, "test\n");
    try std.testing.expectStringStartsWith(buffer, "ERROR [");

    std.fs.cwd().deleteTree("log") catch {};
}

test "auto flush when buffer is full" {
    std.fs.cwd().deleteTree("log") catch {};

    var logger = try Logger.init(std.testing.allocator, null, null, false);
    defer logger.deinit();

    var output = try std.ArrayList(u8).initCapacity(std.testing.allocator, logger.buffer.items.len);
    for (0..logger.buffer.items.len) |i| {
        logger.log(.Debug, "{d}", .{i});

        var buff: [1024]u8 = undefined;
        const data = try std.fmt.bufPrint(&buff, "{d}", .{i});
        try output.appendSlice(data);
    }

    var file = try std.fs.cwd().openFile(Logger.DEFAULT_PATH, .{ .mode = .read_only });
    defer file.close();

    const file_size = (try file.stat()).size;
    const buffer = try std.testing.allocator.alloc(u8, file_size);
    const readed = try file.readAll(buffer);
    _ = readed;
    defer std.testing.allocator.free(buffer);

    try std.testing.expectStringStartsWith(buffer, output.items);

    std.fs.cwd().deleteTree("log") catch {};
}
