//! Formats, queues, and flushes server logs and optional network payload records.
const std = @import("std");
const fs = @import("fs");
const utils = @import("utils.zig");
const builtin = @import("builtin");
const runtime_io = @import("runtime_io");
const sync = @import("sync");

const Agent = @import("background/agent.zig");

/// Serializes formatted log output and owns the underlying log destinations.
pub const Logger = @This();

/// Default file path used when the caller does not specify a log destination.
pub const DEFAULT_PATH: []const u8 = "./log/zcached.log";
/// Initial capacity reserved for formatted log data.
const buffer_size: usize = 4096;
/// Maximum retained log-buffer capacity after a flush.
const max_buffer_size: usize = 256 * 1024;
/// Buffer size at which queued payload records are flushed as a batch.
const batch_size: usize = 64 * 1024;

/// Severity labels written to the log.
pub const LogLevel = enum {
    /// Diagnostic details useful during development.
    Debug,
    /// Normal lifecycle and operational events.
    Info,
    /// Recoverable problems that may need attention.
    Warning,
    /// Failures that prevent an operation from completing.
    Error,
};

/// Direction of a network payload log record.
pub const EType = enum {
    /// Bytes received from a client.
    Request,
    /// Bytes sent to a client.
    Response,
};

/// Allocator for the logger's buffer and queued event records.
allocator: std.mem.Allocator,
/// Optional scheduler used to defer log formatting and writes.
agent: ?*Agent,
/// Periodic flush task, present after `start` succeeds.
flush_task: ?Agent.ScheduledTask = null,
/// Serializes access to the shared buffer and output files.
mutex: sync.Mutex = .{},
/// Cached timestamp text reused until the current second changes.
timestamp: [40]u8 = undefined,
/// Length of the valid prefix in `timestamp`.
timestamp_len: usize = 0,
/// Second represented by the cached timestamp, if initialized.
timestamp_second: ?i64 = null,

/// Append-only log file.
file: fs.File = undefined,
/// Optional stderr mirror, disabled for tests or when stdout logging is off.
stdout: ?fs.File = undefined,
/// Destination path used to open `file`.
log_path: []const u8 = DEFAULT_PATH,

/// Accumulates formatted entries before they are written.
buffer: std.array_list.Managed(u8),

/// Whether formatted messages are also mirrored to stderr.
sout: bool = undefined,

/// Opens the log file and initializes its reusable formatting buffer.
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

/// Records an error-severity message.
pub fn err(self: *Logger, comptime format: []const u8, args: anytype) void {
    self.dispatch(.Error, format, args);
}

/// Records a warning-severity message.
pub fn warn(self: *Logger, comptime format: []const u8, args: anytype) void {
    self.dispatch(.Warning, format, args);
}

/// Records an informational message.
pub fn info(self: *Logger, comptime format: []const u8, args: anytype) void {
    self.dispatch(.Info, format, args);
}

/// Records a debug-severity message.
pub fn debug(self: *Logger, comptime format: []const u8, args: anytype) void {
    self.dispatch(.Debug, format, args);
}

/// Associates the logger with a scheduler and starts its periodic flush task.
pub fn start(self: *Logger, agent: *Agent) !void {
    if (self.flush_task != null) return;
    self.agent = agent;
    self.flush_task = try agent.scheduleCancelable(flushQueued, .{self}, 1);
}

/// Scheduled callback that flushes buffered log output.
fn flushQueued(self: *Logger) void {
    self.flush();
}

/// Schedules formatting when an agent exists, otherwise logs synchronously.
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

/// Unpacks a queued log request and formats it on the agent.
fn logUnpack(args: anytype) void {
    args.logger.log(args.level, args.format, args.args);
}

/// Formats and writes a message while holding the logger mutex.
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

/// Appends a timestamped severity prefix and formatted message.
fn appendLog(self: *Logger, level: LogLevel, comptime format: []const u8, args: anytype) !void {
    try self.appendPrefix(level);
    try self.buffer.print(format ++ "\n", args);
}

/// Appends the cached or freshly formatted timestamp and severity label.
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

/// Stores a network payload and the metadata needed to log it asynchronously.
const EventRecord = struct {
    /// Logger that receives the payload when the queued task runs.
    logger: *Logger,
    /// Allocator used for this record's combined header and payload buffer.
    allocator: std.mem.Allocator,
    /// Whether the record is a request or a response.
    etype: EType,
    /// Payload length following the record header in the same allocation.
    len: usize,

    /// Views the payload bytes stored immediately after this record.
    fn payload(self: *const EventRecord) []const u8 {
        return @as([*]const u8, @ptrCast(self))[@sizeOf(EventRecord) .. @sizeOf(EventRecord) + self.len];
    }

    /// Appends this record to the logger as part of a queued batch.
    fn run(args: ?*const anyopaque) void {
        const record: *const EventRecord = @ptrCast(@alignCast(args.?));
        record.logger.appendEvent(record.etype, record.payload(), true);
    }

    /// Frees the allocation containing both the record and its payload.
    fn destroy(_: std.mem.Allocator, args: ?*const anyopaque) void {
        const record: *const EventRecord = @ptrCast(@alignCast(args.?));
        const bytes: [*]align(@alignOf(EventRecord)) const u8 = @ptrCast(record);
        record.allocator.free(bytes[0 .. @sizeOf(EventRecord) + record.len]);
    }
};

/// Queues a payload log record or appends it synchronously without an agent.
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

/// Appends a payload record under the mutex and flushes according to batch policy.
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

/// Formats a payload record, escaping embedded CRLF sequences.
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

/// Flushes buffered entries while holding the logger mutex.
pub fn flush(self: *Logger) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.flushLocked();
}

/// Writes buffered bytes to disk and releases excess retained capacity.
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

/// Cancels scheduled work, flushes pending entries, and releases owned resources.
pub fn deinit(self: *Logger) void {
    if (self.flush_task) |*task| task.deinit();
    self.flush();
    self.buffer.deinit();
    self.file.close();
}
