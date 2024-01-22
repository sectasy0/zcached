const std = @import("std");
const log = @import("../../src/server/logger.zig");

const handle = @import("../../src/server/err_handler.zig").handle;

test "BadRequest" {
    var buffer: [16]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    const logger = try log.Logger.init(std.testing.allocator, null);
    try handle(&stream, error.BadRequest, .{}, &logger);

    var expected: []u8 = @constCast("-bad request\r\n");

    try std.testing.expectEqualStrings(expected, stream.getWritten());
}

test "UnknownCommand" {
    var buffer: [18]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    const logger = try log.Logger.init(std.testing.allocator, null);
    try handle(&stream, error.UnknownCommand, .{}, &logger);

    var expected: []u8 = @constCast("-unknown command\r\n");

    try std.testing.expectEqualStrings(expected, stream.getWritten());
}

test "UnknownCommand with command name" {
    var buffer: [25]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    const logger = try log.Logger.init(std.testing.allocator, null);
    try handle(&stream, error.UnknownCommand, .{ .command_name = "help" }, &logger);

    try std.testing.expectFmt(
        stream.getWritten(),
        "-unknown command '{s}'\r\n",
        .{"help"},
    );
}

test "unexpected error" {
    var buffer: [15]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    const logger = try log.Logger.init(std.testing.allocator, null);
    try handle(&stream, error.Unexpected, .{}, &logger);

    var expected: []u8 = @constCast("-unexpected\r\n");

    try std.testing.expectEqualStrings(expected, stream.getWritten());
}

test "max clients reached" {
    var buffer: [40]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    const logger = try log.Logger.init(std.testing.allocator, null);
    try handle(&stream, error.MaxClientsReached, .{}, &logger);

    var expected: []u8 = @constCast("-max number of clients reached\r\n");

    try std.testing.expectEqualStrings(expected, stream.getWritten());
}
