const std = @import("std");
const Logger = @import("../../src/server/logger.zig");

const BUFF_SIZE: u8 = 150;

const handle = @import("../../src/server/err_handler.zig").handle;

test "BadRequest" {
    var buffer: [BUFF_SIZE]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    const logger = try Logger.init(std.testing.allocator, null, false);
    try handle(&stream, error.BadRequest, .{}, &logger);

    var expected: []u8 = @constCast("-ERR bad request\r\n");

    try std.testing.expectEqualStrings(expected, stream.getWritten());
}

test "UnknownCommand" {
    var buffer: [BUFF_SIZE]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    const logger = try Logger.init(std.testing.allocator, null, false);
    try handle(&stream, error.UnknownCommand, .{}, &logger);

    var expected: []u8 = @constCast("-ERR unknown command\r\n");

    try std.testing.expectEqualStrings(expected, stream.getWritten());
}

test "UnknownCommand with command name" {
    var buffer: [BUFF_SIZE]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    const logger = try Logger.init(std.testing.allocator, null, false);
    try handle(&stream, error.UnknownCommand, .{ .command = "help" }, &logger);

    try std.testing.expectFmt(
        stream.getWritten(),
        "-ERR unknown command '{s}'\r\n",
        .{"help"},
    );
}

test "unexpected error" {
    var buffer: [BUFF_SIZE]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    const logger = try Logger.init(std.testing.allocator, null, false);
    try handle(&stream, error.Unexpected, .{}, &logger);

    var expected: []u8 = @constCast("-ERR unexpected\r\n");

    try std.testing.expectEqualStrings(expected, stream.getWritten());
}

test "max clients reached" {
    var buffer: [BUFF_SIZE]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    const logger = try Logger.init(std.testing.allocator, null, false);
    try handle(&stream, error.MaxClientsReached, .{}, &logger);

    var expected: []u8 = @constCast("-ERR max number of clients reached\r\n");

    try std.testing.expectEqualStrings(expected, stream.getWritten());
}

test "NotFound with key name" {
    var buffer: [BUFF_SIZE]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    const logger = try Logger.init(std.testing.allocator, null, false);
    try handle(&stream, error.NotFound, .{ .key = "user_cache_12345" }, &logger);

    try std.testing.expectFmt(
        stream.getWritten(),
        "-ERR '{s}' not found\r\n",
        .{"user_cache_12345"},
    );
}
