const std = @import("std");
const fs = @import("fs");
const utils = @import("utils.zig");
const builtin = @import("builtin");

const Agent = @import("background/agent.zig");

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

allocator: std.mem.Allocator,
agent: ?*Agent,

file: fs.File = undefined,
stdout: ?fs.File = undefined,
log_path: []const u8 = DEFAULT_PATH,

buffer: std.array_list.Managed(u8),

sout: bool = undefined,

pub fn init(
    allocator: std.mem.Allocator,
    agent: ?*Agent,
    file_path: ?[]const u8,
    sout: bool,
) !Logger {
    var logger = Logger{
        .allocator = allocator,
        .agent = agent,
        .sout = sout,
        .buffer = try .initCapacity(allocator, buffer_size),
        .stdout = fs.File.stderr(),
    };
    if (file_path != null) logger.log_path = file_path.?;
    utils.createPath(logger.log_path);

    logger.file = try fs.cwd().createFile(
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

pub fn err(self: *Logger, comptime format: []const u8, args: anytype) void {
    self.dispatch(.Error, format, args);
}

pub fn warn(self: *Logger, comptime format: []const u8, args: anytype) void {
    self.dispatch(.Warning, format, args);
}

pub fn info(self: *Logger, comptime format: []const u8, args: anytype) void {
    self.dispatch(.Info, format, args);
}

pub fn debug(self: *Logger, comptime format: []const u8, args: anytype) void {
    self.dispatch(.Debug, format, args);
}

fn dispatch(self: *Logger, level: LogLevel, comptime format: []const u8, args: anytype) void {
    if (self.agent) |agent| {
        agent.schedule(
            logUnpack,
            .{
                .{
                    .logger = self,
                    .level = level,
                    .format = format,
                    .args = args,
                },
            },
            .{},
        ) catch |e| {
            std.log.err("# failed to schedule log message: {any}", .{e});
        };
    } else {
        self.log(level, format, args);
    }
}

fn logUnpack(args: anytype) void {
    args.logger.log(args.level, args.format, args.args);
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

    const start = self.buffer.items.len;
    self.buffer.print("{s} [{s}] " ++ format ++ "\n", .{ log_level, timestamp[0..t_size] } ++ args) catch |e| {
        self.buffer.shrinkRetainingCapacity(start);
        std.log.err("# failed to format log message: {any}", .{e});
        return;
    };

    if (self.stdout) |stdout| {
        stdout.writeAll(self.buffer.items[start..]) catch |e| {
            std.log.err("# failed to write log message to stdout: {any}", .{e});
        };
    }

    self.flush();
}

pub fn logEvent(self: *Logger, etype: EType, payload: []const u8) void {
    const repr = utils.repr(self.allocator, payload) catch |e| {
        self.log(.Error, "* failed to repr payload: {any}", .{e});
        return;
    };

    // background worker will copy it so we can free the original
    defer self.allocator.free(repr);

    switch (etype) {
        .Request => self.info("> request: {s}", .{repr}),
        .Response => self.info("< response: {s}", .{repr}),
    }
}

pub fn flush(self: *Logger) void {
    if (self.buffer.items.len == 0) return;

    self.file.seekFromEnd(0) catch |e| {
        std.log.err("# failed to seek log file: {any}", .{e});
        return;
    };

    _ = self.file.writeAll(self.buffer.items) catch |e| {
        std.log.err("# failed to write log message: {any}", .{e});
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
