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
        error.BulkTooLarge => try out.writeAll("-bulk too large\r\n"),
        error.NotWhitelisted => try out.writeAll("-not whitelisted\r\n"),
        error.DBEmpty => try out.writeAll("-db empty\r\n"),
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
