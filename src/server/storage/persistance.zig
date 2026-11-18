//! Saves and restores the in-memory database using timestamped `.zcpf` snapshot files.
//! Snapshot values use the protocol encoding after a count-bearing file header.

const std = @import("std");
const fs = @import("fs");
const runtime_io = @import("runtime_io");
const sync = @import("sync");
const Agent = @import("../background/agent.zig");

const Config = @import("../config.zig");
const Memory = @import("memory.zig");

// Context changes
const types = @import("../../protocol/types.zig");
const Serializer = @import("../../protocol/deserializer.zig").Deserializer;
const DeserializerT = @import("../../protocol/serializer.zig").SerializerT;
const fixed_buffer_stream = @import("../../protocol/fixed_buffer_stream.zig");
/// Protocol decoder specialized for reading a snapshot from a fixed-buffer reader.
const Deserializer = DeserializerT(fixed_buffer_stream.FixedBufferStream.Reader);

const Logger = @import("../logger.zig");

/// Directory used when no snapshot directory is configured.
const DEFAULT_PATH: []const u8 = "./persist/";

/// Metadata for a candidate snapshot file; `name` is owned by the discovering allocator.
const FileEntry = struct {
    /// Allocated basename of the snapshot file; caller frees the selected entry's name.
    name: []const u8,
    timestamp: i64,
};

/// Snapshot writer and reader bound to a configuration, logger, and storage allocator.
pub const Handler = @This();

/// Allocator for serializer state, temporary buffers, and snapshot paths.
allocator: std.mem.Allocator,

/// Decoder retained for the duration of this handler and released by `deinit`.
deserializer: Deserializer,

/// Server configuration associated with this persistence handler.
config: Config,
/// Logger used for filesystem errors that are handled locally.
logger: *Logger,

/// Configured snapshot directory; initialized to `DEFAULT_PATH` when omitted.
path: ?[]const u8,
save_lock: sync.Mutex = .{},
save_task: ?Agent.ScheduledTask = null,

/// Initializes protocol decoding state and selects the configured or default directory.
pub fn init(
    allocator: std.mem.Allocator,
    config: Config,
    logger: *Logger,
    path: ?[]const u8,
) !Handler {
    return .{
        .allocator = allocator,
        .config = config,
        .deserializer = try Deserializer.init(allocator),
        .logger = logger,
        .path = path orelse config.snapshot.path orelse DEFAULT_PATH,
    };
}

/// Releases the decoder's allocated resources.
pub fn deinit(self: *Handler) void {
    self.stop();
    self.deserializer.deinit();
}

pub fn start(self: *Handler, agent: *Agent, memory: *Memory) !void {
    const interval = self.config.snapshot.interval_secs;
    if (interval == 0 or self.save_task != null) return;
    self.save_task = try agent.scheduleCancelable(saveScheduled, .{ self, memory }, interval);
}

pub fn stop(self: *Handler) void {
    if (self.save_task) |*task| task.deinit();
    self.save_task = null;
}

fn saveScheduled(self: *Handler, memory: *Memory) void {
    _ = self.save(memory) catch |err| {
        self.logger.err("# scheduled snapshot failed: {any}", .{err});
    };
}

/// Writes a snapshot of all memory entries and returns its byte length.
pub fn save(self: *Handler, memory: *Memory) !usize {
    self.save_lock.lock();
    defer self.save_lock.unlock();

    var bytes: std.array_list.Managed(u8) = .init(self.allocator);
    defer bytes.deinit();
    const timestamp = try encodeSnapshot(self.allocator, memory, &bytes);
    const basename = try std.fmt.allocPrint(self.allocator, "dump_{d}.zcpf", .{timestamp});
    defer self.allocator.free(basename);
    const filename = try fs.path.join(
        self.allocator,
        &.{ self.path.?, basename },
    );
    defer self.allocator.free(filename);

    try fs.cwd().makePath(self.path.?);
    const io = runtime_io.get();
    var file = try fs.cwd().inner.createFileAtomic(io, filename, .{ .replace = true });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, bytes.items);
    try file.file.sync(io);
    try file.replace(io);
    memory.last_save.store(timestamp, .monotonic);

    self.prune() catch |err| {
        self.logger.warn("# snapshot saved but retention failed: {any}", .{err});
    };
    return bytes.items.len;
}

fn encodeSnapshot(allocator: std.mem.Allocator, memory: *Memory, bytes: *std.array_list.Managed(u8)) !i64 {
    var iterator = memory.iterator();
    defer iterator.deinit();
    var serializer = Serializer.init(allocator);
    defer serializer.deinit();
    try bytes.print("zcpf%{d}\r\n", .{iterator.count()});
    while (iterator.next()) |item| {
        try bytes.appendSlice(try serializer.process(.{ .str = item.key_ptr.* }));
        try bytes.appendSlice(try serializer.process(item.value_ptr.*));
    }
    return runtime_io.timestamp();
}

fn prune(self: *Handler) !void {
    const keep = self.config.snapshot.keep_last;
    if (keep == 0) return;
    const dir = try fs.cwd().openDir(self.path.?, .{ .follow_symlinks = false, .iterate = true });
    defer dir.close();
    var entries: std.array_list.Managed(FileEntry) = .init(self.allocator);
    defer {
        for (entries.items) |entry| self.allocator.free(entry.name);
        entries.deinit();
    }
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        const timestamp = snapshotTimestamp(entry.name) orelse continue;
        try entries.ensureUnusedCapacity(1);
        entries.appendAssumeCapacity(.{ .name = try self.allocator.dupe(u8, entry.name), .timestamp = timestamp });
    }
    if (entries.items.len <= keep) return;
    std.mem.sort(FileEntry, entries.items, {}, newer);
    for (entries.items[keep..]) |entry| try dir.deleteFile(entry.name);
}

fn newer(_: void, a: FileEntry, b: FileEntry) bool {
    return a.timestamp > b.timestamp;
}

fn snapshotTimestamp(name: []const u8) ?i64 {
    const prefix = "dump_";
    const suffix = ".zcpf";
    if (name.len <= prefix.len + suffix.len or !std.mem.startsWith(u8, name, prefix) or
        !std.mem.endsWith(u8, name, suffix)) return null;
    const digits = name[prefix.len .. name.len - suffix.len];
    if (digits.len > 1 and digits[0] == '0') return null;
    for (digits) |digit| if (!std.ascii.isDigit(digit)) return null;
    return std.fmt.parseInt(i64, digits, 10) catch null;
}

/// Loads the newest validly named snapshot from the configured directory into memory.
/// Returns `InvalidFile` for absent or malformed data; filesystem and storage errors may propagate.
pub fn load(self: *Handler, memory: *Memory) !void {
    const dir = try fs.cwd().openDir(self.path.?, .{
        .follow_symlinks = false,
        .iterate = true,
    });
    defer dir.close();

    const latest_file = try self.getLatestFile(dir) orelse return error.InvalidFile;
    defer self.allocator.free(latest_file.name);

    const file = try dir.openFile(latest_file.name, .{ .mode = .read_only, .follow_symlinks = false });
    defer file.close();

    const size = (try file.stat()).size;
    if (size < "zcpf%0\r\n".len) return error.InvalidFile;
    const buffer = try self.allocator.alloc(u8, size);
    defer self.allocator.free(buffer);

    if (try file.readAll(buffer) != buffer.len) return error.InvalidFile;
    if (!std.mem.eql(u8, buffer[0..4], "zcpf")) return error.InvalidFile;
    defer self.deserializer.reset();
    var stream = fixed_buffer_stream.fixedBufferStream(buffer[4..buffer.len]);
    var reader = stream.reader();

    const bytes = try reader.readUntilDelimiterAlloc(
        self.allocator,
        '\n',
        std.math.maxInt(usize),
    );
    defer self.allocator.free(bytes);

    if (bytes.len < 3 or bytes[0] != '%' or bytes[bytes.len - 1] != '\r') return error.InvalidFile;
    const map_len = std.fmt.parseInt(usize, bytes[1 .. bytes.len - 1], 10) catch {
        return error.InvalidLength;
    };

    for (0..map_len) |_| {
        const key = self.deserializer.process(reader) catch return error.InvalidFile;
        if (key != .str) return error.InvalidFile;
        const value = self.deserializer.process(reader) catch return error.InvalidFile;

        try memory.put(key.str, value);
    }
    memory.last_save.store(latest_file.timestamp, .monotonic);
}

/// Finds the newest regular `.zcpf` file in `dir`, returning owned filename metadata if found.
/// The caller owns and must free the returned entry's `name`.
fn getLatestFile(self: *Handler, dir: fs.Dir) !?FileEntry {
    var latest: ?FileEntry = null;
    errdefer if (latest) |entry| self.allocator.free(entry.name);

    var iterator = dir.iterate();
    while (try iterator.next()) |file| {
        if (file.kind != fs.File.Kind.file) continue;

        const timestamp = snapshotTimestamp(file.name) orelse continue;
        if (latest) |prev| if (prev.timestamp >= timestamp) continue;
        const filename = try self.allocator.dupe(u8, file.name);
        if (latest) |prev| self.allocator.free(prev.name);
        latest = .{ .name = filename, .timestamp = timestamp };
    }

    return latest;
}
