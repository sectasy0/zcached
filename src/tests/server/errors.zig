const std = @import("std");
const Logger = @import("../../server/logger.zig");
const ZType = @import("../../protocol/types.zig").ZType;

const BUFF_SIZE: u8 = 150;

const errors = @import("../../server/processing/errors.zig");

test "Unprocessable" {
    var buffer: [BUFF_SIZE]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    const out_writer = stream.writer().any();

    var logger = try Logger.init(std.testing.allocator, null, null, false);
    defer logger.deinit();
    try errors.handle(out_writer, error.Unprocessable, .{}, &logger);

    try std.testing.expectEqualStrings("-ERR unprocessable\r\n\x03", stream.getWritten());
}

test "UnknownCommand" {
    var buffer: [BUFF_SIZE]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    const out_writer = stream.writer().any();

    var logger = try Logger.init(std.testing.allocator, null, null, false);
    defer logger.deinit();
    var array = std.ArrayList(ZType).initCapacity(std.testing.allocator, 0) catch {
        return error.AllocatorError;
    };
    const args = errors.buildArgs(&array);
    try errors.handle(out_writer, error.UnknownCommand, args, &logger);

    try std.testing.expectEqualStrings("-ERR unknown command\r\n\x03", stream.getWritten());
}

test "UnknownCommand with command name" {
    var buffer: [BUFF_SIZE]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    const out_writer = stream.writer().any();

    var logger = try Logger.init(std.testing.allocator, null, null, false);
    defer logger.deinit();
    var array = std.ArrayList(ZType).initCapacity(std.testing.allocator, 1) catch {
        return error.AllocatorError;
    };
    try array.append(.{ .str = "help" });
    defer array.deinit();

    const args = errors.buildArgs(&array);
    try errors.handle(out_writer, error.UnknownCommand, args, &logger);

    try std.testing.expectFmt(
        stream.getWritten(),
        "-ERR unknown command '{s}'\r\n\x03",
        .{"help"},
    );
}

test "unexpected error" {
    var buffer: [BUFF_SIZE]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    const out_writer = stream.writer().any();

    var logger = try Logger.init(std.testing.allocator, null, null, false);
    defer logger.deinit();
    try errors.handle(out_writer, error.Unexpected, .{}, &logger);

    try std.testing.expectEqualStrings("-ERR unexpected\r\n\x03", stream.getWritten());
}

test "max clients reached" {
    var buffer: [BUFF_SIZE]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    const out_writer = stream.writer().any();

    var logger = try Logger.init(std.testing.allocator, null, null, false);
    defer logger.deinit();
    try errors.handle(out_writer, error.MaxClientsReached, .{}, &logger);

    try std.testing.expectEqualStrings("-ERR max number of clients reached\r\n\x03", stream.getWritten());
}

test "NotFound with key name" {
    var buffer: [BUFF_SIZE]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    const out_writer = stream.writer().any();

    var logger = try Logger.init(std.testing.allocator, null, null, false);
    defer logger.deinit();
    var array = std.ArrayList(ZType).initCapacity(std.testing.allocator, 2) catch {
        return error.AllocatorError;
    };
    try array.append(.{ .str = "help" });
    try array.append(.{ .str = "user_cache_12345" });
    defer array.deinit();

    const args = errors.buildArgs(&array);
    try errors.handle(out_writer, error.NotFound, args, &logger);

    try std.testing.expectFmt(
        stream.getWritten(),
        "-ERR '{s}' not found\r\n\x03",
        .{"user_cache_12345"},
    );
}

test "BusyKey" {
    var buffer: [BUFF_SIZE]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    const out_writer = stream.writer().any();

    var logger = try Logger.init(std.testing.allocator, null, null, false);
    defer logger.deinit();
    try errors.handle(out_writer, error.BusyKey, .{}, &logger);

    try std.testing.expectEqualStrings("-BUSYKEY key already exists\r\n\x03", stream.getWritten());
}
