const std = @import("std");
const Config = @import("../config.zig");

const consts = @import("../network/consts.zig");

const Context = @import("../processing/employer.zig").Context;

const types = @import("../../protocol/types.zig");

const builtin = @import("builtin");

const protocol_handler = @import("../../protocol/handler.zig");
const Commands = @import("../processing/commands.zig");
const Self = @This();

/// Path to the AOF (Append Only File).
/// Stores all write operations and is used to reconstruct
/// the database state after a restart.
const AOF_PATH = "aof.log";

/// Standard buffer size for normal AOF writes.
/// Holds new entries before they are flushed to disk.
/// 8 KiB is a compromise between frequent flushes and memory usage.
pub const BUFFER_SIZE = 8192; // 8 KiB
/// Maximum size for the normal AOF buffer.
/// Prevents excessive memory growth under high load.
pub const BUFFER_MAX_SIZE = 65536; // 64 KiB

/// Buffer used exclusively during rewrite operations.
/// Stores snapshot data and entries accumulated during the rewrite.
/// Normal new writes bypass this buffer and go to the regular buffer,
/// because flushes are disabled while rewrite is in progress.
const REWRITE_BUFFER_SIZE = 65536; // 64 KiB
/// Maximum allowed size for the rewrite buffer in peak load situations.
/// If the buffer grows beyond this, it will be reduced back to
/// `REWRITE_BUFFER_SIZE` after the rewrite completes.
const REWRITE_BUFFER_MAX_SIZE = 262144; // 256 KiB

/// Auto-flush threshold for the normal AOF buffer.
/// When reached, the buffer is written to disk.
/// only applicable for `.auto` strategy.
const AUTO_FLUSH_THRESHOLD = 4096; // 4 KiB

pub const Strategy = Config.AOFConfig.FlushStrategy;
const Protocol = protocol_handler.ProtocolHandlerT(std.io.FixedBufferStream([]u8).Reader);

journal: std.fs.File,
/// Normal buffer for new writes.
buffer: std.array_list.Managed(u8),

/// Buffer used during rewrite (snapshot + merge).
rewrite_buffer: std.array_list.Managed(u8),
/// Flag indicating if rewrite is active, if set flushes are disabled.
rewrite_in_progress: std.atomic.Value(bool) = .init(false),
last_rewrite_size: std.atomic.Value(usize) = .init(0),
rewrite_mutex: std.Thread.Mutex = std.Thread.Mutex{},
rewrite_thread: ?std.Thread = null,
// Queue for snapshot the data before rewrite.
queue: Queue,

size: std.atomic.Value(usize) = .init(0),

test_event: ?std.Thread.ResetEvent = null,

strategy: Strategy,
/// Execution context or environment.
context: Context,

allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, context: Context) !Self {
    const journal = try std.fs.cwd().createFile(
        AOF_PATH,
        .{ .truncate = false },
    );

    var aof: Self = .{
        .journal = journal,
        .strategy = context.config.aof.flush_strategy,
        .context = context,
        .buffer = try std.array_list.Managed(u8).initCapacity(
            allocator,
            BUFFER_SIZE,
        ),
        .rewrite_buffer = try std.array_list.Managed(u8).initCapacity(
            allocator,
            REWRITE_BUFFER_SIZE,
        ),
        .queue = try Queue.init(allocator),
        .allocator = allocator,
    };

    if (builtin.is_test) {
        aof.test_event = std.Thread.ResetEvent{};
    }

    return aof;
}

pub fn append(self: *Self, command: []const u8) !void {
    if (command.len == 0 or self.strategy == .no) return;

    defer {
        if (self.buffer.items.len > BUFFER_MAX_SIZE) {
            self.context.resources.logger.debug(
                "# AOF buffer size exceeded max size ({d}), shrinking from {d} to {d}",
                .{ BUFFER_MAX_SIZE, self.buffer.items.len, BUFFER_SIZE },
            );
            self.buffer.shrinkAndFree(BUFFER_SIZE);
        }
    }

    try self.buffer.appendSlice(command);
    _ = self.size.fetchAdd(command.len, .seq_cst);

    if (command[command.len - 1] != consts.EXT_CHAR) {
        try self.buffer.append(consts.EXT_CHAR);
    }

    if (self.rewrite_in_progress.load(.seq_cst)) {
        return;
    }

    switch (self.strategy) {
        .always => try self.flush(),
        .auto => {
            const threshold_reached = self.buffer.items.len >= AUTO_FLUSH_THRESHOLD;
            if (threshold_reached) {
                try self.flush();
            }
        },
        .everysec => {
            // 操他妈的，把数据写进他妈的队列
        },
        .no => return,
    }

    if (self.rewriteNeeded()) {
        self.size.store(0, .seq_cst);

        std.debug.print("AOF buffer stats: {any} / {d}", .{ self.rewriteNeeded(), self.size.load(.seq_cst) });

        self.queue.enqueue(self.buffer.items) catch |err| {
            self.context.resources.logger.log(
                .Error,
                "# Failed to enqueue AOF buffer: {}",
                .{err},
            );
            return;
        };

        // rewrite in new thread, we don't wait for it
        self.rewrite_thread = try std.Thread.spawn(
            .{},
            Self.rewrite,
            .{self},
        );
    }
}

pub fn replay(self: *Self) !void {
    // read file, allocate memory for it, then parse it
    const journal = try std.fs.cwd().createFile(
        AOF_PATH,
        .{
            .truncate = false,
            .read = true,
        },
    );
    defer journal.close();

    const size = (try journal.stat()).size;

    if (size == 0) return;

    var buffer = try self.allocator.alloc(u8, size);
    defer self.allocator.free(buffer);

    const readed_size = try journal.read(buffer);
    if (readed_size != size) return error.InvalidFile;

    var stream = std.io.fixedBufferStream(buffer[0..buffer.len]);
    const reader = stream.reader();

    var protocol: Protocol = try .init(self.allocator);
    defer protocol.deinit();

    var handler: Commands.Handler = .init(self.allocator, self.context);

    var replayed_commands: usize = 0;
    while (true) {
        const command_bytes = reader.readUntilDelimiterAlloc(
            self.allocator,
            consts.EXT_CHAR,
            std.math.maxInt(usize),
        ) catch |err| {
            if (error.EndOfStream == err) {
                break;
            }
            continue;
        };

        defer self.allocator.free(command_bytes);

        var command_stream = std.io.fixedBufferStream(command_bytes);
        const command_set = protocol.serialize(command_stream.reader()) catch continue;

        if (std.meta.activeTag(command_set) != .array) {
            continue;
        }

        defer command_set.array.deinit();

        var cmd_result = handler.process(&command_set.array);
        if (cmd_result != .ok) {
            continue;
        }

        defer handler.free(&command_set.array, &cmd_result);
        replayed_commands += 1;
    }

    self.context.resources.logger.log(
        .Info,
        "# Successfully replayed {d} commands from the AOF file (total size: {d})",
        .{ replayed_commands, readed_size },
    );
}

pub fn rewrite(self: *Self) void {
    self.rewrite_in_progress.store(true, .seq_cst);
    self.rewrite_mutex.lock();
    defer self.rewrite_mutex.unlock();

    self.context.resources.logger.log(
        .Info,
        "# AOF rewrite started (current size: {d})",
        .{self.size.load(.seq_cst)},
    );

    defer {
        self.rewrite_in_progress.store(false, .seq_cst);

        self.last_rewrite_size.store(self.rewrite_buffer.items.len, .seq_cst);

        if (self.rewrite_buffer.capacity > REWRITE_BUFFER_MAX_SIZE) {
            // If rewrite buffer exceeds max size, shrink it to the default size
            self.context.resources.logger.log(
                .Debug,
                "# AOF rewrite buffer size exceeded max size ({d}), shrinking from {d} to {d}",
                .{ REWRITE_BUFFER_MAX_SIZE, self.rewrite_buffer.capacity, REWRITE_BUFFER_SIZE },
            );
            self.rewrite_buffer.shrinkRetainingCapacity(REWRITE_BUFFER_SIZE);
        }

        self.context.resources.logger.log(
            .Info,
            "# AOF rewrite completed successfully (last_rewrite_size updated to: {d})",
            .{self.rewrite_buffer.items.len},
        );

        self.rewrite_buffer.clearRetainingCapacity();
        self.buffer.clearRetainingCapacity();
        self.rewrite_thread = null;
    }

    if (self.test_event) |_| {
        self.test_event.?.set();
        self.test_event.?.wait();
    }

    // Nothing to rewrite, exiting
    if (self.context.resources.memory.internal.count() == 0) {
        self.context.resources.logger.log(
            .Debug,
            "# No data to rewrite, exiting AOF rewrite",
            .{},
        );
        return;
    }

    const rewritten = std.fs.cwd().createFile(
        "aof_rewritten.log",
        .{ .truncate = false },
    ) catch |err| {
        self.context.resources.logger.log(
            .Error,
            "# Failed to create rewritten AOF file: {}",
            .{err},
        );
        return;
    };

    self.context.resources.memory.lock.lock();
    defer self.context.resources.memory.lock.unlock();

    var handler: Protocol = try .init(self.allocator);
    defer handler.deinit();

    var iterator = self.context.resources.memory.internal.iterator();
    while (iterator.next()) |item| {
        self.rewrite_buffer.appendSlice("*3\r\n$3\r\nSET\r\n") catch |err| {
            self.context.resources.logger.log(
                .Error,
                "# Failed to append command header to rewrite buffer: {}",
                .{err},
            );
            return;
        };

        const key_bytes = handler.deserialize(.{ .str = item.key_ptr.* }) catch |err| {
            self.context.resources.logger.log(
                .Error,
                "# Failed to deserialize item key: {}",
                .{err},
            );
            return;
        };
        self.rewrite_buffer.appendSlice(key_bytes) catch |err| {
            self.context.resources.logger.log(
                .Error,
                "# Failed to append item key to rewrite buffer: {}",
                .{err},
            );
            return;
        };

        const bytes = handler.deserialize(item.value_ptr.*) catch |err| {
            self.context.resources.logger.log(
                .Error,
                "# Failed to deserialize item value: {}",
                .{err},
            );
            return;
        };
        self.rewrite_buffer.appendSlice(bytes) catch |err| {
            self.context.resources.logger.log(
                .Error,
                "# Failed to append item value to rewrite buffer: {}",
                .{err},
            );
            return;
        };

        self.rewrite_buffer.append(consts.EXT_CHAR) catch |err| {
            self.context.resources.logger.log(
                .Error,
                "# Failed to append EXT_CHAR to rewrite buffer: {}",
                .{err},
            );
            return;
        };
    }

    // merge with data appended during rewrite
    const queue_items = self.queue.dequeueAll();
    self.rewrite_buffer.appendSlice(queue_items) catch |err| {
        self.context.resources.logger.log(
            .Error,
            "# Failed to append buffer items to rewrite buffer: {}",
            .{err},
        );
        return;
    };

    rewritten.writeAll(self.rewrite_buffer.items) catch |err| {
        self.context.resources.logger.log(
            .Error,
            "# Failed to write to rewritten AOF file: {}",
            .{err},
        );
        return;
    };

    var delete_error = false;
    const old_journal = self.journal;
    std.fs.cwd().deleteFile(AOF_PATH) catch |err| {
        self.context.resources.logger.log(
            .Error,
            "# Failed to delete old AOF file: {}",
            .{err},
        );
        delete_error = true;
    };

    if (!delete_error) old_journal.close();

    std.fs.cwd().rename("aof_rewritten.log", AOF_PATH) catch |err| {
        self.context.resources.logger.log(
            .Error,
            "# Failed to rename rewritten AOF file: {}",
            .{err},
        );
        return;
    };

    self.journal = rewritten;
}

fn writeInChunks(self: *Self, command: []u8, available: usize, start_pos: usize) !usize {
    const chunks = try std.math.divCeil(usize, command.len, available);

    var position = start_pos;
    for (0..chunks) |i| {
        const start_offset = i * available;
        var copy_end = start_offset + available;
        if (copy_end > command.len) copy_end = command.len;

        const copy_len = copy_end - start_offset;
        @memcpy(
            self.buffer[position .. position + copy_len],
            command[start_offset..copy_end],
        );
        position += copy_len;

        // if last chunk is missing EXT_CHAR
        if (i == chunks - 1 and (copy_len == 0 or self.buffer[position - 1] != consts.EXT_CHAR)) {
            self.buffer[position] = consts.EXT_CHAR;
            position += 1;
        }

        try self.journal.writeAll(self.buffer[0..position]);
        position = 0; // reset position for the next chunk
    }

    return position;
}

pub fn flush(self: *Self) !void {
    if (self.buffer.items.len == 0) return;

    if (self.rewrite_in_progress.load(.seq_cst)) {
        self.context.resources.logger.log(
            .Debug,
            "# AOF flush skipped, rewrite in progress",
            .{},
        );
        return;
    }

    try self.journal.seekFromEnd(0);
    try self.journal.writeAll(self.buffer.items);

    // 他妈的打扫
    self.buffer.clearRetainingCapacity();
}

fn rewriteNeeded(self: *Self) bool {
    const current_size = self.size.load(.seq_cst);
    const last_size = self.last_rewrite_size.load(.seq_cst);
    const rewrite_min_size = self.context.config.aof.rewrite_min_size;
    const rewrite_percentage = self.context.config.aof.rewrite_percentage;

    if (self.rewrite_in_progress.load(.seq_cst)) {
        self.context.resources.logger.log(
            .Debug,
            "# AOF rewrite already in progress, skipping check",
            .{},
        );
        return false;
    }

    // If this is the first rewrite and the current size is large enough
    if (last_size == 0) {
        if (current_size >= rewrite_min_size) {
            self.context.resources.logger.log(
                .Info,
                "# AOF rewrite needed, current size: {d}, last rewrite size: {d}",
                .{ current_size, last_size },
            );
            return true;
        } else {
            return false;
        }
    }

    // Safety check: if current size is 0, do not rewrite
    if (current_size == 0) {
        return false;
    }

    // Prevent underflow: if current_size < last_rewrite_size, no rewrite
    if (current_size <= last_size) {
        return false;
    }

    const growth = current_size - last_size;

    // Safe growth percentage check without overflow
    if (growth * 100 >= last_size * rewrite_percentage) {
        self.context.resources.logger.log(
            .Info,
            "# AOF rewrite needed, current size: {d}, last rewrite size: {d}, growth: {d} ({d}%)",
            .{ current_size, last_size, growth, (growth * 100) / last_size },
        );
        return true;
    }

    return false;
}

pub fn deinit(self: *Self) void {
    self.buffer.deinit();
    self.rewrite_buffer.deinit();
    // self.journal.close();
}

const Queue = struct {
    items: std.array_list.Managed(u8),
    lock: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) !Queue {
        return .{
            .items = std.array_list.Managed(u8).init(allocator),
            .lock = std.Thread.Mutex{},
        };
    }

    pub fn enqueue(self: *Queue, cmd: []u8) !void {
        self.lock.lock();
        defer self.lock.unlock();
        try self.items.appendSlice(cmd);
    }

    pub fn dequeueAll(self: *Queue) []u8 {
        self.lock.lock();
        defer self.lock.unlock();
        const slice = self.items.items;
        self.items.clearRetainingCapacity();
        return slice;
    }

    pub fn deinit(self: *Queue) void {
        self.items.deinit();
    }
};
