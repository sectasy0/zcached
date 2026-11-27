const stdlib = @import("std");
const std = struct {
    pub const testing = stdlib.testing;
    pub const fmt = stdlib.fmt;
    pub const io = struct {
        pub const fixedBufferStream = @import("../../protocol/fixed_buffer_stream.zig").fixedBufferStream;
    };
};
const Logger = @import("../../server/logger.zig");
const errors = @import("../../server/processing/errors.zig");

fn expectReply(err: anyerror, expected: []const u8) !void {
    var buffer: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    var logger = try Logger.init(std.testing.allocator, null, null, false);
    defer logger.deinit();

    try errors.handle(stream.writer().any(), err, &logger);
    try std.testing.expectEqualStrings(expected, stream.getWritten());
}

test "error replies contain only stable error codes" {
    const cases = [_]struct {
        err: anyerror,
        code: []const u8,
    }{
        .{ .err = error.Unprocessable, .code = "UNPROCESSABLE" },
        .{ .err = error.UnknownCommand, .code = "UNKNOWN_COMMAND" },
        .{ .err = error.InvalidType, .code = "INVALID_TYPE" },
        .{ .err = error.InvalidKey, .code = "KEY_NOT_STRING" },
        .{ .err = error.KeyNotString, .code = "KEY_NOT_STRING" },
        .{ .err = error.InvalidCommand, .code = "INVALID_COMMAND" },
        .{ .err = error.InvalidArgs, .code = "INVALID_ARGUMENTS" },
        .{ .err = error.NotFound, .code = "NOT_FOUND" },
        .{ .err = error.MemoryLimitExceeded, .code = "MEMORY_LIMIT_EXCEEDED" },
        .{ .err = error.MaxClientsReached, .code = "MAX_CLIENTS_REACHED" },
        .{ .err = error.PayloadExceeded, .code = "PAYLOAD_EXCEEDED" },
        .{ .err = error.NotWhitelisted, .code = "NOT_WHITELISTED" },
        .{ .err = error.SaveFailure, .code = "SAVE_FAILURE" },
        .{ .err = error.InvalidLength, .code = "INVALID_LENGTH" },
        .{ .err = error.InvalidExpiry, .code = "INVALID_EXPIRY" },
        .{ .err = error.BusyKey, .code = "BUSY_KEY" },
        .{ .err = error.Unexpected, .code = "INTERNAL_ERROR" },
    };

    for (cases) |case| {
        const expected = try std.fmt.allocPrint(
            std.testing.allocator,
            "-{s}\r\n\x03",
            .{case.code},
        );
        defer std.testing.allocator.free(expected);
        try expectReply(case.err, expected);
    }
}

test "error replies never include request-controlled text" {
    try expectReply(error.UnknownCommand, "-UNKNOWN_COMMAND\r\n\x03");
    try expectReply(error.NotFound, "-NOT_FOUND\r\n\x03");
}
