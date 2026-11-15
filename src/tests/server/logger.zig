const std = @import("std");
const fs = @import("fs");

const Logger = @import("../../server/logger.zig");
const Agent = @import("../../server/background/agent.zig");

test "queued logger dispatch preserves levels and owns event payloads" {
    const allocator = std.testing.allocator;
    const path = "./tmp/queued-network-payload.log";
    fs.cwd().deleteFile(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    var logger = try Logger.init(allocator, null, path, false);
    defer {
        logger.deinit();
        fs.cwd().deleteFile(path) catch |err| std.log.err("Failed to remove test log: {any}", .{err});
    }
    var running: std.atomic.Value(bool) = .init(true);
    var agent = try Agent.init(allocator, &running);
    defer agent.deinit();
    logger.agent = &agent;
    defer logger.agent = null;

    const payload = try allocator.dupe(u8, "before\r\nafter");
    defer allocator.free(payload);
    logger.err("error value {d}", .{1});
    logger.warn("warning value {d}", .{2});
    logger.info("{s}", .{payload});
    logger.debug("debug value {d}", .{3});
    logger.logEvent(.Request, payload);
    logger.logEvent(.Response, payload);
    @memset(payload, 'x');

    // Execute only after the caller has reused its input buffer.
    for (0..6) |_| {
        var task = agent.queue.dequeue();
        task.executeAndDestroy(allocator);
    }

    var file = try fs.cwd().openFile(path, .{ .mode = .read_only });
    defer file.close();
    const bytes = try allocator.alloc(u8, (try file.stat()).size);
    defer allocator.free(bytes);
    try std.testing.expectEqual(bytes.len, try file.readAll(bytes));
    try std.testing.expectStringStartsWith(bytes, "ERROR [");
    for ([_][]const u8{
        "] error value 1\nWARN [",
        "] warning value 2\nINFO [",
        "] before\r\nafter\nDEBUG [",
        "] debug value 3\nINFO [",
        "] > request: before\\r\\nafter\nINFO [",
    }) |expected| {
        try std.testing.expect(std.mem.indexOf(u8, bytes, expected) != null);
    }
    try std.testing.expectStringEndsWith(bytes, "] < response: before\\r\\nafter\n");
}

test "logger preserves network payloads larger than its initial buffer" {
    const path = "./tmp/network-payload.log";
    fs.cwd().deleteFile(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    var logger = try Logger.init(std.testing.allocator, null, path, false);
    defer {
        logger.deinit();
        fs.cwd().deleteFile(path) catch |err| std.log.err("Failed to remove test log: {any}", .{err});
    }
    const payload: [16384]u8 = @splat('x');
    logger.logEvent(.Response, &payload);

    var file = try fs.cwd().openFile(path, .{ .mode = .read_only });
    defer file.close();
    const bytes = try std.testing.allocator.alloc(u8, (try file.stat()).size);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqual(bytes.len, try file.readAll(bytes));
    try std.testing.expectStringStartsWith(bytes, "INFO [");
    try std.testing.expectStringEndsWith(bytes, "< response: " ++ payload ++ "\n");
}

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
