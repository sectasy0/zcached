const std = @import("std");
const fs = @import("fs");
const utils = @import("utils.zig");
const builtin = @import("builtin");
const runtime_io = @import("runtime_io");
const sync = @import("sync");

const Agent = @import("background/agent.zig");

pub const Logger = @This();

pub const DEFAULT_PATH: []const u8 = "./log/zcached.log";
const buffer_size: usize = 4096;
const max_buffer_size: usize = 256 * 1024;
const batch_size: usize = 64 * 1024;

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
flush_task: ?Agent.ScheduledTask = null,
mutex: sync.Mutex = .{},
timestamp: [40]u8 = undefined,
timestamp_len: usize = 0,
timestamp_second: ?i64 = null,

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

pub fn start(self: *Logger, agent: *Agent) !void {
    if (self.flush_task != null) return;
    self.agent = agent;
    self.flush_task = try agent.scheduleCancelable(flushQueued, .{self}, 1);
}

fn flushQueued(self: *Logger) void {
    self.flush();
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
    self.mutex.lock();
    defer self.mutex.unlock();
    const offset = self.buffer.items.len;
    self.appendLog(level, format, args) catch |e| {
        self.buffer.shrinkRetainingCapacity(offset);
        std.log.err("# failed to format log message: {any}", .{e});
        return;
    };

    if (self.stdout) |stdout| {
        stdout.writeAll(self.buffer.items[offset..]) catch |e| {
            std.log.err("# failed to write log message to stdout: {any}", .{e});
        };
    }

    self.flushLocked();
}

fn appendLog(self: *Logger, level: LogLevel, comptime format: []const u8, args: anytype) !void {
    try self.appendPrefix(level);
    try self.buffer.print(format ++ "\n", args);
}

fn appendPrefix(self: *Logger, level: LogLevel) !void {
    const second = runtime_io.timestamp();
    if (self.timestamp_second == null or self.timestamp_second.? != second) {
        self.timestamp_len = utils.timestampf(&self.timestamp);
        self.timestamp_second = second;
    }
    const name = switch (level) {
        .Debug => "DEBUG",
        .Info => "INFO",
        .Warning => "WARN",
        .Error => "ERROR",
    };
    try self.buffer.print("{s} [{s}] ", .{ name, self.timestamp[0..self.timestamp_len] });
}

const EventRecord = struct {
    logger: *Logger,
    allocator: std.mem.Allocator,
    etype: EType,
    len: usize,

    fn payload(self: *const EventRecord) []const u8 {
        return @as([*]const u8, @ptrCast(self))[@sizeOf(EventRecord) .. @sizeOf(EventRecord) + self.len];
    }

    fn run(args: ?*const anyopaque) void {
        const record: *const EventRecord = @ptrCast(@alignCast(args.?));
        record.logger.appendEvent(record.etype, record.payload(), true);
    }

    fn destroy(_: std.mem.Allocator, args: ?*const anyopaque) void {
        const record: *const EventRecord = @ptrCast(@alignCast(args.?));
        const bytes: [*]align(@alignOf(EventRecord)) const u8 = @ptrCast(record);
        record.allocator.free(bytes[0 .. @sizeOf(EventRecord) + record.len]);
    }
};

pub fn logEvent(self: *Logger, etype: EType, payload: []const u8) void {
    const agent = self.agent orelse {
        self.appendEvent(etype, payload, false);
        return;
    };
    const bytes = self.allocator.alignedAlloc(u8, .of(EventRecord), @sizeOf(EventRecord) + payload.len) catch |e| {
        std.log.err("# failed to allocate network log record: {any}", .{e});
        return;
    };
    const record: *EventRecord = @ptrCast(bytes.ptr);
    record.* = .{ .logger = self, .allocator = self.allocator, .etype = etype, .len = payload.len };
    @memcpy(bytes[@sizeOf(EventRecord)..], payload);
    agent.queue.enqueueTask(.{ .run = EventRecord.run, .destroy = EventRecord.destroy, .args = record }) catch |e| {
        self.allocator.free(bytes);
        std.log.err("# failed to schedule network log record: {any}", .{e});
    };
}

fn appendEvent(self: *Logger, etype: EType, payload: []const u8, batched: bool) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    const offset = self.buffer.items.len;
    self.appendEventLocked(etype, payload) catch |e| {
        self.buffer.shrinkRetainingCapacity(offset);
        std.log.err("# failed to format network log record: {any}", .{e});
        return;
    };
    if (self.stdout) |stdout| {
        stdout.writeAll(self.buffer.items[offset..]) catch |e| {
            std.log.err("# failed to write network log to stdout: {any}", .{e});
        };
    }
    if (!batched or self.buffer.items.len >= batch_size) self.flushLocked();
}

fn appendEventLocked(self: *Logger, etype: EType, payload: []const u8) !void {
    try self.appendPrefix(.Info);
    try self.buffer.appendSlice(switch (etype) {
        .Request => "> request: ",
        .Response => "< response: ",
    });
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, payload, offset, "\r\n")) |end| {
        try self.buffer.appendSlice(payload[offset..end]);
        try self.buffer.appendSlice("\\r\\n");
        offset = end + 2;
    }
    try self.buffer.appendSlice(payload[offset..]);
    try self.buffer.append('\n');
}

pub fn flush(self: *Logger) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.flushLocked();
}

fn flushLocked(self: *Logger) void {
    if (self.buffer.items.len == 0) return;

    self.file.seekFromEnd(0) catch |e| {
        std.log.err("# failed to seek log file: {any}", .{e});
        return;
    };

    _ = self.file.writeAll(self.buffer.items) catch |e| {
        std.log.err("# failed to write log message: {any}", .{e});
        return;
    };

    if (self.buffer.capacity > max_buffer_size) {
        self.buffer.clearAndFree();
    } else {
        self.buffer.clearRetainingCapacity();
    }
}

pub fn deinit(self: *Logger) void {
    if (self.flush_task) |*task| task.deinit();
    self.flush();
    self.buffer.deinit();
    self.file.close();
}
