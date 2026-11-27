//! Converts command-processing errors into the server's wire-format error replies.
//! Client-facing error replies contain stable codes only, never request text.
const Logger = @import("../logger.zig");
const consts = @import("../network/consts.zig");

/// Logs `err`, writes its stable code and terminator to `out`, and propagates I/O failures.
pub fn handle(out: anytype, err: anyerror, logger: *Logger) !void {
    logger.debug("event=command_error code={s}", .{@errorName(err)});

    const code = switch (err) {
        error.Unprocessable => "UNPROCESSABLE",
        error.UnknownCommand => "UNKNOWN_COMMAND",
        error.InvalidType => "INVALID_TYPE",
        error.InvalidKey, error.KeyNotString => "KEY_NOT_STRING",
        error.InvalidCommand => "INVALID_COMMAND",
        error.InvalidArgs => "INVALID_ARGUMENTS",
        error.NoAuth => "NOAUTH",
        error.InvalidCredentials => "INVALID_CREDENTIALS",
        error.NoPermission => "NO_PERMISSION",
        error.AuthRateLimited => "AUTH_RATE_LIMITED",
        error.AuthTimeout => "AUTH_TIMEOUT",
        error.NotFound => "NOT_FOUND",
        error.MemoryLimitExceeded => "MEMORY_LIMIT_EXCEEDED",
        error.MaxClientsReached => "MAX_CLIENTS_REACHED",
        error.PayloadExceeded => "PAYLOAD_EXCEEDED",
        error.ResponseTooLarge => "RESPONSE_TOO_LARGE",
        error.NotWhitelisted => "NOT_WHITELISTED",
        error.SaveFailure => "SAVE_FAILURE",
        error.SaveInProgress => "SAVE_IN_PROGRESS",
        error.InvalidLength => "INVALID_LENGTH",
        error.InvalidExpiry => "INVALID_EXPIRY",
        error.BusyKey => "BUSY_KEY",
        else => "INTERNAL_ERROR",
    };

    try out.writeByte('-');
    try out.writeAll(code);
    try out.writeAll("\r\n");
    try out.writeByte(consts.EXT_CHAR);
}
