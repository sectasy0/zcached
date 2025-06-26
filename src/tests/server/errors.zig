const std = @import("std");
const Logger = @import("../../server/logger.zig");
const ZType = @import("../../protocol/types.zig").ZType;

const BUFF_SIZE: u8 = 150;

const errors = @import("../../server/processing/errors.zig");

test "BadRequest" {
    var buffer: [BUFF_SIZE]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    const out_writer = stream.writer();

    var logger = try Logger.init(std.testing.allocator, null, false);
    try errors.handle(&out_writer, error.BadRequest, .{}, &logger);

    const expected: []u8 = @constCast("-ERR bad request\r\n");

    try std.testing.expectEqualStrings(expected, stream.getWritten());
}

test "UnknownCommand" {
    var buffer: [BUFF_SIZE]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    const out_writer = stream.writer();

    var logger = try Logger.init(std.testing.allocator, null, false);
    var array = std.ArrayList(ZType).initCapacity(std.testing.allocator, 0) catch {
        return error.AllocatorError;
    };
    const args = errors.build_args(&array);
    try errors.handle(&out_writer, error.UnknownCommand, args, &logger);

    const expected: []u8 = @constCast("-ERR unknown command\r\n");

    try std.testing.expectEqualStrings(expected, stream.getWritten());
}

test "UnknownCommand with command name" {
    var buffer: [BUFF_SIZE]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    const out_writer = stream.writer();

    var logger = try Logger.init(std.testing.allocator, null, false);
    var array = std.ArrayList(ZType).initCapacity(std.testing.allocator, 1) catch {
        return error.AllocatorError;
    };
    try array.append(.{ .str = @constCast("help") });
    defer array.deinit();

    const args = errors.build_args(&array);
    try errors.handle(&out_writer, error.UnknownCommand, args, &logger);

    try std.testing.expectFmt(
        stream.getWritten(),
        "-ERR unknown command '{s}'\r\n",
        .{"help"},
    );
}

test "unexpected error" {
    var buffer: [BUFF_SIZE]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    const out_writer = stream.writer();

    var logger = try Logger.init(std.testing.allocator, null, false);
    try errors.handle(&out_writer, error.Unexpected, .{}, &logger);

    const expected: []u8 = @constCast("-ERR unexpected\r\n");

    try std.testing.expectEqualStrings(expected, stream.getWritten());
}

test "max clients reached" {
    var buffer: [BUFF_SIZE]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    const out_writer = stream.writer();

    var logger = try Logger.init(std.testing.allocator, null, false);
    try errors.handle(&out_writer, error.MaxClientsReached, .{}, &logger);

    const expected: []u8 = @constCast("-ERR max number of clients reached\r\n");

    try std.testing.expectEqualStrings(expected, stream.getWritten());
}

test "NotFound with key name" {
    var buffer: [BUFF_SIZE]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    const out_writer = stream.writer();

    var logger = try Logger.init(std.testing.allocator, null, false);
    var array = std.ArrayList(ZType).initCapacity(std.testing.allocator, 2) catch {
        return error.AllocatorError;
    };
    try array.append(.{ .str = @constCast("help") });
    try array.append(.{ .str = @constCast("user_cache_12345") });
    defer array.deinit();

    const args = errors.build_args(&array);
    try errors.handle(&out_writer, error.NotFound, args, &logger);

    try std.testing.expectFmt(
        stream.getWritten(),
        "-ERR '{s}' not found\r\n",
        .{"user_cache_12345"},
    );
}

test "KeyAlreadyExists" {
    var buffer: [BUFF_SIZE]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    const out_writer = stream.writer();

    var logger = try Logger.init(std.testing.allocator, null, false);
    try errors.handle(&out_writer, error.KeyAlreadyExists, .{}, &logger);

    const expected: []u8 = @constCast("-ERR key already exists\r\n");

    try std.testing.expectEqualStrings(expected, stream.getWritten());
}
