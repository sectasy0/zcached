const std = @import("std");
const utils = @import("utils.zig");
const builtin = @import("builtin");

pub const Logger = @This();

pub const DEFAULT_PATH: []const u8 = "./log/zcached.log";
const buffer_size: usize = 4096;
const max_buffer_size: usize = 256 * 1024;

pub const LogLevel = enum {
    Debug,
    Info,
    Warning,
    Error,
};

pub const EType = enum {
    Request,
    Response,
};

file: std.fs.File = undefined,
stdout: ?std.fs.File = undefined,
log_path: []const u8 = DEFAULT_PATH,

buffer: std.ArrayList(u8),

sout: bool = undefined,

allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, file_path: ?[]const u8, sout: bool) !Logger {
    var logger = Logger{
        .allocator = allocator,
        .sout = sout,
        .buffer = try .initCapacity(allocator, buffer_size),
        .stdout = std.io.getStdOut(),
    };
    if (file_path != null) logger.log_path = file_path.?;
    utils.createPath(logger.log_path);

    logger.file = try std.fs.cwd().createFile(
        logger.log_path,
        .{ .read = true, .truncate = false },
    );

    var timestamp: [40]u8 = undefined;
    const t_size = utils.timestampf(&timestamp);

    std.debug.print(
        "INFO [{s}] * logger initialized, log_path: {s}\n",
        .{ timestamp[0..t_size], logger.log_path },
    );

    if (builtin.is_test or !logger.sout) {
        logger.stdout = null;
    }

    return logger;
}

pub fn log(self: *Logger, level: LogLevel, comptime format: []const u8, args: anytype) void {
    var timestamp: [40]u8 = undefined;
    const t_size = utils.timestampf(&timestamp);

    const log_level = switch (level) {
        LogLevel.Debug => "DEBUG",
        LogLevel.Info => "INFO",
        LogLevel.Warning => "WARN",
        LogLevel.Error => "ERROR",
    };

    var buf: [buffer_size]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, format, args) catch |err| {
        std.log.err("# failed to format log message: {?}", .{err});
        return;
    };

    var fbuf: [buffer_size]u8 = undefined;
    const formatted = std.fmt.bufPrint(&fbuf, "{s} [{s}] {s}\n", .{
        log_level,
        timestamp[0..t_size],
        message,
    }) catch |err| {
        std.log.err("# failed to format log message: {?}", .{err});
        return;
    };

    if (self.stdout) |stdout| {
        stdout.writeAll(formatted) catch |err| {
            std.log.err("# failed to write log message to stdout: {?}", .{err});
        };
    }

    self.buffer.appendSlice(formatted) catch |err| {
        std.log.err("# failed to buffer log message: {?}", .{err});
        return;
    };

    if (self.buffer.items.len + formatted.len >= self.buffer.capacity) {
        self.flush();
    }
}

pub fn log_event(self: *Logger, etype: EType, payload: []const u8) void {
    const repr = utils.repr(self.allocator, payload) catch |err| {
        self.log(.Error, "* failed to repr payload: {any}", .{err});
        return;
    };
    defer self.allocator.free(repr);

    switch (etype) {
        .Request => self.log(
            .Info,
            "> request: {s}",
            .{repr},
        ),
        .Response => self.log(
            .Info,
            "> response: {s}",
            .{repr},
        ),
    }
}

pub fn flush(self: *Logger) void {
    if (self.buffer.items.len == 0) return;

    self.file.seekFromEnd(0) catch |err| {
        std.log.err("# failed to seek log file: {?}", .{err});
        return;
    };

    _ = self.file.writeAll(self.buffer.items) catch |err| {
        std.log.err("# failed to write log message: {?}", .{err});
        return;
    };

    if (self.buffer.items.len > max_buffer_size) {
        self.buffer.shrinkAndFree(buffer_size);
    } else {
        self.buffer.clearRetainingCapacity();
    }
}

pub fn deinit(self: *Logger) void {
    self.flush();
    self.buffer.deinit();
    self.file.close();
}
