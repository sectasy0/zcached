//! Saves and restores the in-memory database using timestamped `.zcpf` snapshot files.
//! Snapshot values use the protocol encoding after a count-bearing file header.

const std = @import("std");
const fs = @import("fs");
const runtime_io = @import("runtime_io");

const Config = @import("../config.zig");
const Memory = @import("memory.zig");

// Context changes
const types = @import("../../protocol/types.zig");
const Serializer = @import("../../protocol/deserializer.zig").Deserializer;
const DeserializerT = @import("../../protocol/serializer.zig").SerializerT;
const fixed_buffer_stream = @import("../../protocol/fixed_buffer_stream.zig");
/// Protocol decoder specialized for reading a snapshot from a fixed-buffer reader.
const Deserializer = DeserializerT(fixed_buffer_stream.FixedBufferStream.Reader);

const utils = @import("../utils.zig");
const Logger = @import("../logger.zig");

/// Directory used when no snapshot directory is configured.
const DEFAULT_PATH: []const u8 = "./persist/";

/// Metadata for a candidate snapshot file; `name` is owned by the discovering allocator.
const FileEntry = struct {
    /// Allocated basename of the snapshot file; caller frees the selected entry's name.
    name: []const u8,
    /// Creation time in nanoseconds, used to select the newest snapshot.
    ctime: i128,
    /// Snapshot size in bytes, used for the read buffer.
    size: usize,
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

/// Initializes protocol decoding state and selects the configured or default directory.
pub fn init(
    allocator: std.mem.Allocator,
    config: Config,
    logger: *Logger,
    path: ?[]const u8,
) !Handler {
    var persister = Handler{
        .allocator = allocator,
        .config = config,
        .deserializer = try Deserializer.init(allocator),
        .logger = logger,
        .path = path,
    };

    if (persister.path == null) persister.path = DEFAULT_PATH;

    return persister;
}

/// Releases the decoder's allocated resources.
pub fn deinit(self: *Handler) void {
    self.deserializer.deinit();
}

/// Writes a snapshot of all memory entries and returns its byte length.
/// The returned count is zero when file creation fails; other serialization and I/O errors propagate.
pub fn save(self: *Handler, memory: *Memory) !usize {
    var serializer = Serializer.init(self.allocator);
    defer serializer.deinit();

    var bytes = std.array_list.Managed(u8).init(self.allocator);
    defer bytes.deinit();

    const header = try std.fmt.allocPrint(
        self.allocator,
        "zcpf%{d}\r\n",
        .{memory.size()},
    );
    defer self.allocator.free(header);

    try bytes.appendSlice(header);

    const timestamp = runtime_io.timestamp();
    const filename = try std.fmt.allocPrint(
        self.allocator,
        "{s}dump_{d}.zcpf",
        .{ self.path.?, timestamp },
    );
    defer self.allocator.free(filename);

    utils.createPath(filename);

    const file = fs.cwd().createFile(
        filename,
        .{ .truncate = false },
    ) catch |err| {
        self.logger.err("failed to open persistance file: {any}", .{err});
        return 0;
    };
    defer file.close();

    var iterator = memory.internal.iterator();
    while (iterator.next()) |item| {
        const key = try serializer.process(.{ .str = item.key_ptr.* });
        try bytes.appendSlice(key);

        const value = try serializer.process(item.value_ptr.*);

        try bytes.appendSlice(value);
    }

    const payload = bytes.toOwnedSlice() catch return 0;
    defer self.allocator.free(payload);

    try file.writeAll(payload);
    memory.last_save = timestamp;

    return payload.len;
}

/// Loads the newest validly named snapshot from the configured directory into memory.
/// Returns `InvalidFile` for absent or malformed data; filesystem and storage errors may propagate.
pub fn load(self: *Handler, memory: *Memory) !void {
    var dir = try fs.cwd().openDir(self.path.?, .{
        .follow_symlinks = false,
        .access_sub_paths = false,
        .iterate = true,
    });
    defer dir.close();

    const latest = self.getLatestFile(dir) catch |err| {
        self.logger.err(
            "failed to get latest file from {s}: {any}",
            .{ self.path.?, err },
        );
        return;
    };

    const latest_file = latest orelse return error.InvalidFile;
    defer self.allocator.free(latest_file.name);

    const filename = try std.fmt.allocPrint(
        self.allocator,
        "{s}{s}",
        .{ self.path.?, latest_file.name },
    );
    defer self.allocator.free(filename);

    const file = fs.cwd().openFile(filename, .{ .mode = .read_only }) catch |err| {
        self.logger.err(
            "failed to open file {s}: {any}",
            .{ filename, err },
        );
        return;
    };
    defer file.close();

    if (latest.?.size == 0) return;

    var buffer = try self.allocator.alloc(u8, latest.?.size);
    defer self.allocator.free(buffer);

    const readed_size = try file.read(buffer);
    if (readed_size != latest.?.size) return error.InvalidFile;
    if (!std.mem.eql(u8, buffer[0..4], "zcpf")) return error.InvalidFile;
    const file_name = latest.?.name;

    const underscore_index: usize = std.mem.indexOf(u8, file_name, "_").?;
    const dot_index: usize = std.mem.indexOf(u8, file_name, ".").?;
    const str_timestamp: []const u8 = file_name[underscore_index + 1 .. dot_index];

    memory.last_save = try std.fmt.parseInt(i64, str_timestamp, 10);

    var stream = fixed_buffer_stream.fixedBufferStream(buffer[4..buffer.len]);
    var reader = stream.reader();

    const bytes = try reader.readUntilDelimiterAlloc(
        self.allocator,
        '\n',
        std.math.maxInt(usize),
    );
    defer self.allocator.free(bytes);

    const map_len = std.fmt.parseInt(usize, bytes[1 .. bytes.len - 1], 10) catch {
        return error.InvalidLength;
    };

    for (0..map_len) |_| {
        const key = self.deserializer.process(reader) catch return error.InvalidFile;
        const value = self.deserializer.process(reader) catch return error.InvalidFile;

        try memory.put(key.str, value);
    }
}

/// Finds the newest regular `.zcpf` file in `dir`, returning owned filename metadata if found.
/// The caller owns and must free the returned entry's `name`.
fn getLatestFile(self: *Handler, dir: fs.Dir) !?FileEntry {
    var latest: ?FileEntry = null;

    var iterator = dir.iterate();
    while (try iterator.next()) |file| {
        if (file.kind != fs.File.Kind.file) continue;

        var iter = std.mem.splitBackwardsSequence(u8, file.name, ".");
        if (!std.mem.eql(u8, iter.first(), "zcpf")) continue;

        const file_path = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.path.?, file.name });
        defer self.allocator.free(file_path);

        const filename = try self.allocator.dupe(u8, file.name);

        const stat = try fs.cwd().statFile(file_path);

        if (latest) |prev| {
            if (stat.ctime.nanoseconds <= prev.ctime) {
                // This file is older or the same age – we don't need the `filename` we just duplicated
                self.allocator.free(filename);
                continue;
            }
            // The new file is newer – free the previous `latest.name` before updating
            self.allocator.free(prev.name);
        }

        latest = .{
            .name = filename,
            .ctime = stat.ctime.nanoseconds,
            .size = stat.size,
        };
    }

    return latest;
}
