const std = @import("std");

const Config = @import("config.zig");
const MemoryStorage = @import("storage.zig");

// Context changes
const Serializer = @import("../protocol/deserializer.zig").Deserializer;
const DeserializerT = @import("../protocol/serializer.zig").SerializerT;
const Deserializer = DeserializerT(std.io.FixedBufferStream([]u8).Reader);

const types = @import("../protocol/types.zig");
const utils = @import("utils.zig");
const log = @import("logger.zig");
const time = @import("std").time;

const DEFAULT_PATH: []const u8 = "./persist/";

const FileEntry = struct { name: []const u8, ctime: i128, size: usize };

pub const PersistanceHandler = @This();

arena: std.heap.ArenaAllocator,

serializer: Serializer,
deserializer: Deserializer,

config: Config,
logger: log.Logger,

path: ?[]const u8,

pub fn init(
    allocator: std.mem.Allocator,
    config: Config,
    logger: log.Logger,
    path: ?[]const u8,
) !PersistanceHandler {
    var persister = PersistanceHandler{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .config = config,
        .serializer = Serializer.init(allocator),
        .deserializer = try Deserializer.init(allocator),
        .logger = logger,
        .path = path,
    };

    if (persister.path == null) persister.path = DEFAULT_PATH;

    return persister;
}

pub fn deinit(self: *PersistanceHandler) void {
    self.arena.deinit();
    self.serializer.deinit();
    self.deserializer.deinit();
}

pub fn save(self: *PersistanceHandler, storage: *MemoryStorage) !usize {
    const allocator = self.arena.allocator();
    var bytes = std.ArrayList(u8).init(allocator);

    const header = try std.fmt.allocPrint(
        allocator,
        "zcpf%{d}\r\n",
        .{storage.size()},
    );
    try bytes.appendSlice(header);

    const timestamp: i64 = time.timestamp();
    const filename = try std.fmt.allocPrint(
        allocator,
        "{s}dump_{d}.zcpf",
        .{ self.path.?, timestamp },
    );

    utils.create_path(filename);

    const file = std.fs.cwd().createFile(
        filename,
        .{ .truncate = false },
    ) catch |err| {
        self.logger.log(
            log.LogLevel.Error,
            "failed to open persistance file: {?}",
            .{err},
        );
        return 0;
    };
    defer file.close();

    var iterator = storage.internal.iterator();
    while (iterator.next()) |item| {
        const key = try self.serializer.process(.{ .str = @constCast(item.key_ptr.*) });
        try bytes.appendSlice(key);

        const value = try self.serializer.process(item.value_ptr.*);

        try bytes.appendSlice(value);
    }

    const payload = bytes.toOwnedSlice() catch return 0;

    try file.writeAll(payload);

    return payload.len;
}

// have to load latest file from `self.path`
pub fn load(self: *PersistanceHandler, storage: *MemoryStorage) !void {
    var dir = try std.fs.cwd().openIterableDir(self.path.?, .{
        .no_follow = true,
        .access_sub_paths = false,
    });
    defer dir.close();

    const latest = self.get_latest_file(dir) catch |err| {
        self.logger.log(
            log.LogLevel.Error,
            "failed to get latest file from {s}: {?}",
            .{ self.path.?, err },
        );
        return;
    };

    if (latest == null) return error.FileNotFound;

    const filename = try std.fmt.allocPrint(
        self.arena.allocator(),
        "{s}{s}",
        .{ self.path.?, latest.?.name },
    );

    const file = std.fs.cwd().openFile(filename, .{ .mode = .read_only }) catch |err| {
        self.logger.log(
            log.LogLevel.Error,
            "failed to open file {s}: {?}",
            .{ filename, err },
        );
        return;
    };
    defer file.close();

    if (latest.?.size == 0) return;

    var buffer = try self.arena.allocator().alloc(u8, latest.?.size);
    defer self.arena.allocator().free(buffer);

    const readed_size = try file.read(buffer);
    if (readed_size != latest.?.size) return error.InvalidFile;
    if (!std.mem.eql(u8, buffer[0..4], "zcpf")) return error.InvalidFile;

    var stream = std.io.fixedBufferStream(buffer[4..buffer.len]);
    var reader = stream.reader();

    const bytes = try reader.readUntilDelimiterAlloc(
        self.arena.allocator(),
        '\n',
        std.math.maxInt(usize),
    );

    const map_len = std.fmt.parseInt(usize, bytes[1 .. bytes.len - 1], 10) catch {
        return error.InvalidLength;
    };

    for (0..map_len) |_| {
        const key = self.deserializer.process(reader) catch {
            return error.InvalidFile;
        };

        const value = self.deserializer.process(reader) catch {
            return error.InvalidFile;
        };

        try storage.put(key.str, value);
    }
}

fn get_latest_file(self: *PersistanceHandler, dir: std.fs.IterableDir) !?FileEntry {
    var latest: ?FileEntry = null;

    var iterator = dir.iterate();
    while (try iterator.next()) |file| {
        if (file.kind != std.fs.File.Kind.file) continue;

        var iter = std.mem.splitBackwardsSequence(u8, file.name, ".");
        if (!std.mem.eql(u8, iter.first(), "zcpf")) continue;

        // we don't want to allocate everything without freeing, so
        const allocator = self.arena.allocator();
        const file_path = try std.fmt.allocPrint(
            allocator,
            "{s}{s}",
            .{ self.path.?, file.name },
        );
        defer allocator.free(file_path);

        const stat = try std.fs.cwd().statFile(file_path);
        if (latest == null) {
            latest = .{
                .name = file.name,
                .ctime = stat.ctime,
                .size = stat.size,
            };

            continue;
        }

        if (stat.ctime > latest.?.ctime) {
            latest = .{
                .name = file.name,
                .ctime = stat.ctime,
                .size = stat.size,
            };
        }
    }

    return latest;
}
