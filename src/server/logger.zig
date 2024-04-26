const std = @import("std");
const utils = @import("utils.zig");

const Logger = @This();

pub const DEFAULT_PATH: []const u8 = "./logs/zcached.log";
const MAX_FILE_SIZE: usize = 30_000_000;
const BUFFER_SIZE: usize = 4096;

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
file_size: usize = 0,
file: std.fs.File = undefined,
log_path: []const u8 = DEFAULT_PATH,

sout: bool = undefined,

allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, file_path: ?[]const u8, sout: bool) !Logger {
    var logger = Logger{ .allocator = allocator, .sout = sout };
    if (file_path != null) logger.log_path = file_path.?;
    utils.create_path(logger.log_path);

    logger.file = try logger.get_log_file(true);

    var timestamp: [40]u8 = undefined;
    const t_size: usize = utils.timestampf(&timestamp);
    const logs_path: ?[]const u8 = std.fs.path.dirname(logger.log_path);

    std.debug.print(
        "INFO [{s}] * logger initialized, logs_path: {s}\n",
        .{ timestamp[0..t_size], logs_path.? },
    );
    try logger.file.seekFromEnd(0);
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

    var buf: [BUFFER_SIZE]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, format, args) catch |err| {
        std.log.err("# failed to format log message: {?}", .{err});
        return;
    };

    var fbuf: [BUFFER_SIZE]u8 = undefined;
    const formatted = std.fmt.bufPrint(&fbuf, "{s} [{s}] {s}\n", .{
        log_level,
        timestamp[0..t_size],
        message,
    }) catch |err| {
        std.log.err("# failed to format log message: {?}", .{err});
        return;
    };

    if (self.sout) std.debug.print("{s}", .{formatted});

    self.file_size += formatted.len;
    if (self.file_size >= MAX_FILE_SIZE) self.file = self.get_log_file(false) catch |err| {
        std.log.err("# failed to obtain a new log file: {?}", .{err});
        return;
    };

    _ = self.file.write(formatted) catch |err| {
        std.log.err("# failed to write log message: {?}", .{err});
        return;
    };
}

pub fn log_event(self: *Logger, etype: EType, payload: []const u8) void {
    const repr = utils.repr(self.allocator, payload) catch |err| {
        self.log(.Error, "* failed to repr payload: {any}", .{err});
        return;
    };
    defer self.allocator.free(repr);

    switch (etype) {
        EType.Request => self.log(
            .Info,
            "> request: {s}",
            .{repr},
        ),
        EType.Response => self.log(
            .Info,
            "> response: {s}",
            .{repr},
        ),
    }
}

pub fn get_latest_file_path(self: *const Logger) ![]const u8 {
    const fs = std.fs;

    var iterator = std.mem.splitBackwards(u8, self.log_path, "/");
    const base_filename: []const u8 = iterator.first();

    // In theory, we could use the remaining elements in the iterator to determine the path,
    // but this is easier way (i'm lazy).
    const dir_path: []const u8 = fs.path.dirname(self.log_path).?;
    const dir: fs.IterableDir = try fs.cwd().openIterableDir(dir_path, .{});

    var dir_iterator = dir.iterate();
    var file_index: usize = 1;

    while (try dir_iterator.next()) |entry| {
        if (std.mem.startsWith(u8, entry.name, base_filename)) file_index += 1;
    }
    if (file_index > 1) file_index -= 1;

    return try std.fmt.allocPrint(
        self.allocator,
        "{s}.{}",
        .{ self.log_path, file_index },
    );
}

pub fn get_log_file(self: *Logger, fetch_latest_file_size: bool) !std.fs.File {
    if (!fetch_latest_file_size and self.file_size < MAX_FILE_SIZE) return self.file;

    const file_path: []const u8 = try self.get_latest_file_path();
    defer self.allocator.free(file_path);

    if (fetch_latest_file_size) {
        // This should be done only at the startup.
        const file: std.fs.File = try std.fs.cwd().createFile(file_path, .{
            .read = true,
        });
        const file_stat = try file.stat();
        self.file_size = file_stat.size;

        if (file_stat.size < MAX_FILE_SIZE) return file;
    }
    // We need to create a new log file.
    self.file_size = 0;

    var it = std.mem.splitBackwards(u8, file_path, ".");
    var file_index: usize = try std.fmt.parseInt(usize, it.next().?, 10);
    file_index += 1;

    const new_file_path: []const u8 = try std.fmt.allocPrint(
        self.allocator,
        "{s}.{}",
        .{ self.log_path, file_index },
    );
    defer self.allocator.free(new_file_path);

    const file: std.fs.File = try std.fs.cwd().createFile(
        new_file_path,
        .{ .read = true, .truncate = false },
    );

    var timestamp: [40]u8 = undefined;
    const t_size: usize = utils.timestampf(&timestamp);

    std.debug.print(
        "INFO [{s}] * new log file initialized at path: {s}\n",
        .{ timestamp[0..t_size], new_file_path },
    );

    return file;
}
