const std = @import("std");
const Logger = @import("../../src/server/logger.zig");
const ZType = @import("../../src/protocol/types.zig").ZType;

const BUFF_SIZE: u8 = 150;

const err_handler = @import("../../src/server/err_handler.zig");

test "BadRequest" {
    var buffer: [BUFF_SIZE]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    var logger = try Logger.init(std.testing.allocator, null, false);
    try err_handler.handle(&stream, error.BadRequest, .{}, &logger);

    const expected: []u8 = @constCast("-ERR bad request\r\n");

    try std.testing.expectEqualStrings(expected, stream.getWritten());
}

test "UnknownCommand" {
    var buffer: [BUFF_SIZE]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    var logger = try Logger.init(std.testing.allocator, null, false);
    var array = std.ArrayList(ZType).initCapacity(std.testing.allocator, 0) catch {
        return error.AllocatorError;
    };
    const args = err_handler.build_args(&array);
    try err_handler.handle(&stream, error.UnknownCommand, args, &logger);

    const expected: []u8 = @constCast("-ERR unknown command\r\n");

    try std.testing.expectEqualStrings(expected, stream.getWritten());
}

test "UnknownCommand with command name" {
    var buffer: [BUFF_SIZE]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    var logger = try Logger.init(std.testing.allocator, null, false);
    var array = std.ArrayList(ZType).initCapacity(std.testing.allocator, 1) catch {
        return error.AllocatorError;
    };
    try array.append(.{ .str = @constCast("help") });
    defer array.deinit();

    const args = err_handler.build_args(&array);
    try err_handler.handle(&stream, error.UnknownCommand, args, &logger);

    try std.testing.expectFmt(
        stream.getWritten(),
        "-ERR unknown command '{s}'\r\n",
        .{"help"},
    );
}

test "unexpected error" {
    var buffer: [BUFF_SIZE]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    var logger = try Logger.init(std.testing.allocator, null, false);
    try err_handler.handle(&stream, error.Unexpected, .{}, &logger);

    const expected: []u8 = @constCast("-ERR unexpected\r\n");

    try std.testing.expectEqualStrings(expected, stream.getWritten());
}

test "max clients reached" {
    var buffer: [BUFF_SIZE]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    var logger = try Logger.init(std.testing.allocator, null, false);
    try err_handler.handle(&stream, error.MaxClientsReached, .{}, &logger);

    const expected: []u8 = @constCast("-ERR max number of clients reached\r\n");

    try std.testing.expectEqualStrings(expected, stream.getWritten());
}

test "NotFound with key name" {
    var buffer: [BUFF_SIZE]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    var logger = try Logger.init(std.testing.allocator, null, false);
    var array = std.ArrayList(ZType).initCapacity(std.testing.allocator, 2) catch {
        return error.AllocatorError;
    };
    try array.append(.{ .str = @constCast("help") });
    try array.append(.{ .str = @constCast("user_cache_12345") });
    defer array.deinit();

    const args = err_handler.build_args(&array);
    try err_handler.handle(&stream, error.NotFound, args, &logger);

    try std.testing.expectFmt(
        stream.getWritten(),
        "-ERR '{s}' not found\r\n",
        .{"user_cache_12345"},
    );
}
