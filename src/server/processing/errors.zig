//! Converts command-processing errors into the server's wire-format error replies.
//! Diagnostic arguments borrow slices from the decoded request only for the duration of handling.

const std = @import("std");
const Logger = @import("../logger.zig");
const consts = @import("../network/consts.zig");

const ZType = @import("../../protocol/types.zig").ZType;

/// Optional command and key context used to make selected error replies more specific.
pub const Args = struct {
    /// Borrowed command name, absent when the request has no string command token.
    command: ?[]const u8 = null,
    /// Borrowed first argument when it is a string, typically the relevant key.
    key: ?[]const u8 = null,
};

/// Extracts string command/key context without allocating or taking ownership.
pub fn buildArgs(command_set: *const std.array_list.Managed(ZType)) Args {
    var args: Args = Args{};

    if (command_set.items.len < 1) return args;
    if (command_set.items[0] == .str) args.command = command_set.items[0].str;
    if (command_set.items.len < 2) return args;
    if (command_set.items[1] == .str) args.key = command_set.items[1].str;

    return args;
}

/// Logs `err`, writes its protocol error body and terminator to `out`, and propagates I/O failures.
pub fn handle(out: anytype, err: anyerror, args: Args, logger: *Logger) !void {
    logger.debug("handling error: {}", .{err});

    _ = switch (err) {
        error.Unprocessable => try out.writeAll("-ERR unprocessable\r\n"),
        error.UnknownCommand => try handleUnknownCommand(out, args),
        error.InvalidType => try out.writeAll("-TYPERR invalid type\r\n"),
        error.InvalidKey => try out.writeAll("-ERR key must be a string\r\n"),
        error.NotFound => try handleNotFound(out, args),
        error.MaxClientsReached => try out.writeAll("-ERR max number of clients reached\r\n"),
        error.PayloadExceeded => try out.writeAll("-ERR maximum payload size exceeded\r\n"),
        error.NotWhitelisted => try out.writeAll("-NOAUTH not whitelisted\r\n"),
        error.SaveFailure => try out.writeAll("-NOSAVE error while saving data\r\n"),
        error.InvalidLength => try out.writeAll("-INVAL invalid length\r\n"),
        error.BusyKey => try out.writeAll("-BUSYKEY key already exists\r\n"),
        else => try out.writeAll("-ERR unexpected\r\n"),
    };

    try out.writeByte(consts.EXT_CHAR);
}

/// Writes an unknown-command reply, including the command name when available.
fn handleUnknownCommand(out: anytype, args: Args) !void {
    if (args.command) |command| {
        try out.print("-ERR unknown command '{s}'\r\n", .{command});
    } else {
        try out.writeAll("-ERR unknown command\r\n");
    }
}

/// Writes a not-found reply, including the key when available.
fn handleNotFound(out: anytype, args: Args) !void {
    if (args.key) |key| {
        try out.print("-ERR '{s}' not found\r\n", .{key});
    } else {
        try out.writeAll("-ERR not found\r\n");
    }
}
