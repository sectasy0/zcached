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

    self.prune(basename) catch |err| {
        self.logger.warn("# snapshot saved but retention failed: {any}", .{err});
    };
    return bytes.items.len;
}

fn encodeSnapshot(allocator: std.mem.Allocator, memory: *Memory, bytes: *std.array_list.Managed(u8)) !i64 {
    var iterator = memory.iterator();
    defer iterator.deinit();
    var serializer = Serializer.init(allocator);
    defer serializer.deinit();
    var body: std.array_list.Managed(u8) = .init(allocator);
    defer body.deinit();
    while (iterator.next()) |item| {
        try body.appendSlice(try serializer.process(.{ .str = item.key_ptr.* }));
        try body.appendSlice(try serializer.process(item.value_ptr.*));
        try body.print(":{d}\r\n", .{item.expired_at});
    }
    const checksum = crc32(body.items);
    try bytes.print("zcpf%{d}\r\n:{x:0>8}\r\n", .{ iterator.count(), checksum });
    try bytes.appendSlice(body.items);
    return runtime_io.timestamp();
}

fn prune(self: *Handler, protected_name: []const u8) !void {
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

    var kept_others: usize = 0;
    for (entries.items) |entry| {
        if (std.mem.eql(u8, entry.name, protected_name)) continue;
        if (kept_others < keep - 1) {
            kept_others += 1;
            continue;
        }
        try dir.deleteFile(entry.name);
    }
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

fn crc32(bytes: []const u8) u32 {
    var crc = std.hash.Crc32.init();
    crc.update(bytes);
    return crc.final();
}

/// Loads the newest validly named snapshot from the configured directory into memory.
/// Returns `InvalidFile` for absent or malformed data; filesystem and storage errors may propagate.
pub fn load(self: *Handler, memory: *Memory) !void {
    try self.loadSnapshot(memory, false);
}

/// Retains historical entries until the AOF overlay has been replayed.
pub fn loadForReplay(self: *Handler, memory: *Memory) !void {
    memory.fabric.replaying = true;
    defer memory.fabric.replaying = false;
    try self.loadSnapshot(memory, true);
}

fn loadSnapshot(self: *Handler, memory: *Memory, historical: bool) !void {
    const dir = try fs.cwd().openDir(self.path.?, .{
        .follow_symlinks = false,
        .iterate = true,
    });
    defer dir.close();
    var candidates = try std.array_list.Managed(FileEntry).initCapacity(self.allocator, 8);
    defer {
        for (candidates.items) |entry| self.allocator.free(entry.name);
        candidates.deinit();
    }
    var iterator = dir.iterate();
    while (try iterator.next()) |file| {
        if (file.kind != fs.File.Kind.file) continue;
        const timestamp = snapshotTimestamp(file.name) orelse continue;
        try candidates.append(.{ .name = try self.allocator.dupe(u8, file.name), .timestamp = timestamp });
    }
    if (candidates.items.len == 0) return error.InvalidFile;
    std.mem.sort(FileEntry, candidates.items, {}, newer);

    var corruption_seen = false;
    for (candidates.items) |candidate| {
        const file = dir.openFile(candidate.name, .{ .mode = .read_only, .follow_symlinks = false }) catch continue;
        defer file.close();

        const size = (file.stat() catch continue).size;
        if (size < "zcpf%0\r\n".len) {
            corruption_seen = true;
            continue;
        }
        const buffer = self.allocator.alloc(u8, size) catch continue;
        defer self.allocator.free(buffer);
        if (file.readAll(buffer) catch continue != buffer.len) {
            corruption_seen = true;
            continue;
        }

        if (!std.mem.eql(u8, buffer[0..4], "zcpf")) {
            corruption_seen = true;
            continue;
        }
        if (buffer[4] != '%') {
            corruption_seen = true;
            continue;
        }
        const payload_start: usize = 4;
        var stream = fixed_buffer_stream.fixedBufferStream(buffer[payload_start..]);
        var reader = stream.reader();
        const header = reader.readUntilDelimiterAlloc(self.allocator, '\n', std.math.maxInt(usize)) catch {
            corruption_seen = true;
            continue;
        };
        defer self.allocator.free(header);
        if (header.len < 2 or header[0] != '%' or header[header.len - 1] != '\r') {
            corruption_seen = true;
            continue;
        }
        const map_len = std.fmt.parseInt(usize, header[1 .. header.len - 1], 10) catch {
            corruption_seen = true;
            continue;
        };
        const checksum_offset = payload_start + stream.pos;
        if (checksum_offset + 11 > buffer.len or buffer[checksum_offset] != ':' or
            buffer[checksum_offset + 9] != '\r' or buffer[checksum_offset + 10] != '\n')
        {
            corruption_seen = true;
            continue;
        }
        const checksum_text = buffer[checksum_offset + 1 .. checksum_offset + 9];
        for (checksum_text) |digit| {
            if (!std.ascii.isHex(digit)) {
                corruption_seen = true;
                break;
            }
        } else {
            const expected = std.fmt.parseUnsigned(u32, checksum_text, 16) catch {
                corruption_seen = true;
                continue;
            };
            stream.pos += 11;
            if (crc32(buffer[payload_start + stream.pos ..]) != expected) {
                corruption_seen = true;
                continue;
            }
            // Continue only after a valid required checksum.
        }

        self.deserializer.reset();
        defer self.deserializer.reset();
        var valid = true;
        for (0..map_len) |_| {
            const key = self.deserializer.process(reader) catch {
                valid = false;
                break;
            };
            if (key != .str) {
                valid = false;
                break;
            }
            const value = self.deserializer.process(reader) catch {
                valid = false;
                break;
            };
            const expiry = self.deserializer.process(reader) catch {
                valid = false;
                break;
            };
            if (expiry != .int or expiry.int < 0) {
                valid = false;
                break;
            }
            _ = value;
        }
        if (!valid or (stream.pos < buffer[payload_start..].len and
            !std.mem.eql(u8, buffer[payload_start + stream.pos ..], "\x03")))
        {
            corruption_seen = true;
            continue;
        }

        self.deserializer.reset();
        var stream2 = fixed_buffer_stream.fixedBufferStream(buffer[payload_start..]);
        var reader2 = stream2.reader();
        const apply_header = reader2.readUntilDelimiterAlloc(self.allocator, '\n', std.math.maxInt(usize)) catch continue;
        defer self.allocator.free(apply_header);
        const apply_checksum_offset = payload_start + stream2.pos;
        if (apply_checksum_offset + 11 <= buffer.len) stream2.pos += 11;
        const now = if (historical) 0 else Memory.unixMillis();
        for (0..map_len) |_| {
            const key = self.deserializer.process(reader2) catch continue;
            if (key != .str) continue;
            const value = self.deserializer.process(reader2) catch continue;
            const expiry = self.deserializer.process(reader2) catch continue;
            if (expiry != .int or expiry.int < 0) continue;
            const deadline = expiry.int;
            if (deadline != 0 and deadline <= now) continue;
            try memory.putExpiring(key.str, value, deadline);
        }
        memory.last_save.store(candidate.timestamp, .monotonic);
        if (corruption_seen) {
            self.logger.warn("# loaded fallback snapshot {s}; newer corruption detected", .{candidate.name});
        }
        return;
    }
    return error.InvalidFile;
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
