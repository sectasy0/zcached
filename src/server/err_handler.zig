const std = @import("std");
const Logger = @import("logger.zig");

const ZType = @import("../protocol/types.zig").ZType;
// That handler exists because I wanna have control over what is sent to the client

const Args = struct {
    command: ?[]const u8 = null,
    key: ?[]const u8 = null,
};

pub fn build_args(command_set: *const std.ArrayList(ZType)) Args {
    var args: Args = Args{};

    if (command_set.items.len < 1) return args;
    if (command_set.items[0] == .str) args.command = command_set.items[0].str;
    if (command_set.items.len < 2) return args;
    if (command_set.items[1] == .str) args.key = command_set.items[1].str;

    return args;
}

// stream is a std.net.Stream
pub fn handle(stream: anytype, err: anyerror, args: Args, logger: *Logger) !void {
    const out = stream.writer();

    logger.log(.Debug, "handling error: {}", .{err});

    _ = switch (err) {
        error.BadRequest => try out.writeAll("-ERR bad request\r\n"),
        error.UnknownCommand => try handle_unknown_command(out, args),
        error.NotInteger => try out.writeAll("-TYPERR not integer\r\n"),
        error.NotBoolean => try out.writeAll("-TYPERR not boolean\r\n"),
        error.KeyNotString => try out.writeAll("-TYPERR key not string\r\n"),
        error.NotFound => try handle_not_found(out, args),
        error.MaxClientsReached => try out.writeAll("-ERR max number of clients reached\r\n"),
        error.BulkTooLarge => try out.writeAll("-ERR bulk too large\r\n"),
        error.NotWhitelisted => try out.writeAll("-ERR not whitelisted\r\n"),
        error.SaveFailure => try out.writeAll("-ERR there is no data to save\r\n"),
        else => try out.writeAll("-ERR unexpected\r\n"),
    };
}

fn handle_unknown_command(out: anytype, args: Args) !void {
    if (args.command) |command| {
        try out.print("-ERR unknown command '{s}'\r\n", .{command});
    } else {
        try out.writeAll("-ERR unknown command\r\n");
    }
}

fn handle_not_found(out: anytype, args: Args) !void {
    if (args.key) |key| {
        try out.print("-ERR '{s}' not found\r\n", .{key});
    } else {
        try out.writeAll("-ERR not found\r\n");
    }
}
