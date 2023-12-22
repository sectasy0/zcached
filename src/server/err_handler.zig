const std = @import("std");
const log = @import("logger.zig");
// That handler exists because I wanna have control over what is sent to the client

const Args = struct {
    command_name: ?[]const u8 = null,
};
// stream is a std.net.Stream
pub fn handle(stream: anytype, err: anyerror, args: Args, logger: *const log.Logger) !void {
    const out = stream.writer();

    logger.log(log.LogLevel.Debug, "handling error: {}", .{err});

    _ = switch (err) {
        error.BadRequest => try out.writeAll("-bad request\r\n"),
        error.UnknownCommand => try handle_unknown_command(out, args),
        error.NotInteger => try out.writeAll("-not integer\r\n"),
        error.NotBoolean => try out.writeAll("-not boolean\r\n"),
        error.KeyNotString => try out.writeAll("-key not string\r\n"),
        error.NotFound => try out.writeAll("-not found\r\n"),
        error.MaxClientsReached => try out.writeAll("-max number of clients reached\r\n"),
        error.NotAllowed => try out.writeAll("-not allowed\r\n"),
        else => try out.writeAll("-unexpected\r\n"),
    };
}

fn handle_unknown_command(out: anytype, args: Args) !void {
    if (args.command_name) |command_name| {
        try out.print("-unknown command '{s}'\r\n", .{command_name});
    } else {
        try out.writeAll("-unknown command\r\n");
    }
}

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
