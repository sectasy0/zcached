const std = @import("std");
const utils = @import("utils.zig");

const DEFAULT_PATH: []const u8 = "./log/zcached.log";
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
pub const Logger = struct {
    file: std.fs.File = undefined,
    log_path: []const u8 = DEFAULT_PATH,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, file_path: ?[]const u8) !Logger {
        var logger = Logger{ .allocator = allocator };

        if (file_path != null) logger.log_path = file_path.?;
        utils.create_path(logger.log_path);

        logger.file = try std.fs.cwd().createFile(
            logger.log_path,
            .{ .read = true, .truncate = false },
        );

        var timestamp: [40]u8 = undefined;
        const t_size = utils.timestampf(&timestamp);

        std.debug.print(
            "INFO [{s}] logger initialized, log_path: {s}\n",
            .{ timestamp[0..t_size], logger.log_path },
        );

        return logger;
    }

    pub fn log(self: *const Logger, level: LogLevel, comptime format: []const u8, args: anytype) void {
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
            std.log.err("failed to format log message: {?}", .{err});
            return;
        };

        var fbuf: [BUFFER_SIZE]u8 = undefined;
        const formatted = std.fmt.bufPrint(&fbuf, "{s} [{s}] {s}\n", .{
            log_level,
            timestamp[0..t_size],
            message,
        }) catch |err| {
            std.log.err("failed to format log message: {?}", .{err});
            return;
        };

        self.file.seekFromEnd(0) catch |err| {
            std.log.err("failed to seek to end of log file: {?}", .{err});
            return;
        };

        std.debug.print("{s}", .{formatted});

        self.file.writeAll(formatted) catch |err| {
            std.log.err("failed to write log message: {?}", .{err});
            return;
        };
    }

    pub fn log_event(self: *const Logger, etype: EType, payload: []const u8) void {
        const repr = utils.repr(self.allocator, payload) catch |err| {
            self.log(LogLevel.Error, "* failed to repr payload: {any}", .{err});
            return;
        };
        defer self.allocator.free(repr);

        switch (etype) {
            EType.Request => self.log(
                LogLevel.Info,
                "> request: {s}",
                .{repr},
            ),
            EType.Response => self.log(
                LogLevel.Info,
                "> response: {s}",
                .{repr},
            ),
        }
    }
};

test "test logger debug" {
    std.fs.cwd().deleteTree("log") catch {};
    var logger = try Logger.init(
        std.testing.allocator,
        null,
    );
    logger.log(LogLevel.Debug, "{s}", .{"test"});

    var file = try std.fs.cwd().openFile(DEFAULT_PATH, .{ .mode = .read_only });
    defer file.close();

    const file_size = (try file.stat()).size;
    var buffer = try std.testing.allocator.alloc(u8, file_size);
    const readed = try file.readAll(buffer);
    _ = readed;
    defer std.testing.allocator.free(buffer);

    try std.testing.expectStringEndsWith(buffer, "test\n");
    try std.testing.expectStringStartsWith(buffer, "DEBUG [");

    std.fs.cwd().deleteTree("log") catch {};
}

test "test logger info" {
    std.fs.cwd().deleteTree("log") catch {};
    var logger = try Logger.init(std.testing.allocator, null);
    logger.log(LogLevel.Info, "{s}", .{"test"});

    var file = try std.fs.cwd().openFile(DEFAULT_PATH, .{ .mode = .read_only });
    defer file.close();

    const file_size = (try file.stat()).size;
    var buffer = try std.testing.allocator.alloc(u8, file_size);
    const readed = try file.readAll(buffer);
    _ = readed;
    defer std.testing.allocator.free(buffer);

    try std.testing.expectStringEndsWith(buffer, "test\n");
    try std.testing.expectStringStartsWith(buffer, "INFO [");

    std.fs.cwd().deleteTree("log") catch {};
}

test "test logger warning" {
    std.fs.cwd().deleteTree("log") catch {};
    var logger = try Logger.init(std.testing.allocator, null);
    logger.log(LogLevel.Warning, "{s}", .{"test"});

    var file = try std.fs.cwd().openFile(DEFAULT_PATH, .{ .mode = .read_only });
    defer file.close();

    const file_size = (try file.stat()).size;
    var buffer = try std.testing.allocator.alloc(u8, file_size);
    const readed = try file.readAll(buffer);
    _ = readed;
    defer std.testing.allocator.free(buffer);

    try std.testing.expectStringEndsWith(buffer, "test\n");
    try std.testing.expectStringStartsWith(buffer, "WARN [");

    std.fs.cwd().deleteTree("log") catch {};
}

test "test logger error" {
    std.fs.cwd().deleteTree("log") catch {};
    var logger = try Logger.init(std.testing.allocator, null);
    logger.log(LogLevel.Error, "{s}", .{"test"});

    var file = try std.fs.cwd().openFile(DEFAULT_PATH, .{ .mode = .read_only });
    defer file.close();

    const file_size = (try file.stat()).size;
    var buffer = try std.testing.allocator.alloc(u8, file_size);
    const readed = try file.readAll(buffer);
    _ = readed;
    defer std.testing.allocator.free(buffer);

    try std.testing.expectStringEndsWith(buffer, "test\n");
    try std.testing.expectStringStartsWith(buffer, "ERROR [");

    std.fs.cwd().deleteTree("log") catch {};
}
