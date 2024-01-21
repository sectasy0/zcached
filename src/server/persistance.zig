const std = @import("std");

const Config = @import("config.zig").Config;
const MemoryStorage = @import("storage.zig").MemoryStorage;

// Context changes
const Serializer = @import("../protocol/deserializer.zig").Deserializer;
const DeserializerT = @import("../protocol/serializer.zig").SerializerT;
const Deserializer = DeserializerT(std.io.FixedBufferStream([]u8).Reader);

const TracingAllocator = @import("tracing.zig").TracingAllocator;
const types = @import("../protocol/types.zig");
const utils = @import("utils.zig");
const log = @import("logger.zig");
const time = @import("std").time;

const DEFAULT_PATH: []const u8 = "./persist/";

const FileEntry = struct { name: []const u8, ctime: i128, size: usize };

pub const PersistanceHandler = struct {
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
            .{storage.internal.count()},
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
            var key = try self.serializer.process(.{ .str = @constCast(item.key_ptr.*) });
            try bytes.appendSlice(key);

            var value = try self.serializer.process(item.value_ptr.*);

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

        std.debug.print("{d}", .{latest.?.size});

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
            var key = self.deserializer.process(reader) catch {
                return error.InvalidFile;
            };

            var value = self.deserializer.process(reader) catch {
                return error.InvalidFile;
            };

            try storage.internal.put(key.str, value);
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
};

test "should save" {
    std.fs.cwd().makePath("./tmp/persist") catch {};

    var config = try Config.load(std.testing.allocator, null, null);
    defer config.deinit();

    var logger = try log.Logger.init(std.testing.allocator, null);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        null,
    );

    defer persister.deinit();

    var tracing_allocator = TracingAllocator.init(std.testing.allocator);
    var storage = MemoryStorage.init(tracing_allocator.allocator(), config, &persister);
    defer storage.deinit();

    try storage.put("test1", .{ .str = @constCast("testtest") });
    try storage.put("test2", .{ .str = @constCast("testtest") });
    try storage.put("test3", .{ .str = @constCast("testtest") });
    try storage.put("test4", .{ .str = @constCast("testtest") });

    const result = try persister.save(&storage);

    try std.testing.expectEqual(result, 108);

    std.fs.cwd().deleteDir("./tmp/persist") catch {};
}

test "should load" {
    std.fs.cwd().makePath("./tmp/persist") catch {};
    std.fs.cwd().deleteFile("./tmp/persist/dump_latest.zcpf") catch {};

    var config = try Config.load(std.testing.allocator, null, null);
    defer config.deinit();

    var logger = try log.Logger.init(std.testing.allocator, null);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        "./tmp/persist/",
    );
    defer persister.deinit();

    var tracing_allocator = TracingAllocator.init(std.testing.allocator);
    var storage = MemoryStorage.init(tracing_allocator.allocator(), config, &persister);
    defer storage.deinit();

    try std.testing.expectEqual(storage.internal.count(), 0);

    const file_content = "zcpf%4\r\n$5\r\ntest2\r\n$8\r\ntesttest\r\n$5\r\ntest1\r\n$8\r\ntesttest\r\n$5\r\ntest3\r\n$8\r\ntesttest\r\n$5\r\ntest4\r\n$8\r\ntesttest\r\n";
    const file = try std.fs.cwd().createFile("./tmp/persist/dump_latest.zcpf", .{});
    try file.writeAll(file_content);
    defer file.close();

    try persister.load(&storage);

    try std.testing.expectEqual(storage.internal.count(), 4);

    std.fs.cwd().deleteFile("./tmp/persist/dump_latest.zcpf") catch {};
    std.fs.cwd().deleteDir("./tmp/persist") catch {};
}

test "should not load without header" {
    std.fs.cwd().makePath("./tmp/persist") catch {};
    var config = try Config.load(std.testing.allocator, null, null);
    defer config.deinit();

    var logger = try log.Logger.init(std.testing.allocator, null);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        "./tmp/persist/without_header/",
    );
    defer persister.deinit();

    var tracing_allocator = TracingAllocator.init(std.testing.allocator);
    var storage = MemoryStorage.init(tracing_allocator.allocator(), config, &persister);
    defer storage.deinit();

    std.fs.cwd().makeDir("./tmp/persist/without_header") catch {};

    try std.testing.expectEqual(storage.internal.count(), 0);

    const file_content = "%4\r\n$5\r\ntest2\r\n$8\r\ntesttest\r\n$5\r\ntest1\r\n$8\r\ntesttest\r\n$5\r\ntest3\r\n$8\r\ntesttest\r\n$5\r\ntest4\r\n$8\r\ntesttest";
    const file = try std.fs.cwd().createFile("./tmp/persist/without_header/dump_latest_invalid.zcpf", .{});
    try file.writeAll(file_content);
    defer file.close();

    try std.testing.expectEqual(persister.load(&storage), error.InvalidFile);

    std.fs.cwd().deleteFile("./tmp/persist/without_header/dump_latest_invalid.zcpf") catch {};
    std.fs.cwd().deleteDir("./tmp/persist") catch {};
}

test "should not load invalid ext" {
    std.fs.cwd().makePath("./tmp/persist") catch {};

    var config = try Config.load(std.testing.allocator, null, null);
    defer config.deinit();

    var logger = try log.Logger.init(std.testing.allocator, null);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        "./tmp/persist/invalid_ext/",
    );
    defer persister.deinit();

    var tracing_allocator = TracingAllocator.init(std.testing.allocator);
    var storage = MemoryStorage.init(tracing_allocator.allocator(), config, &persister);
    defer storage.deinit();

    std.fs.cwd().makeDir("./tmp/persist/invalid_ext") catch {};

    try std.testing.expectEqual(storage.internal.count(), 0);

    const file_content = "%4\r\n$5\r\ntest2\r\n$8\r\ntesttest\r\n$5\r\ntest1\r\n$8\r\ntesttest\r\n$5\r\ntest3\r\n$8\r\ntesttest\r\n$5\r\ntest4\r\n$8\r\ntesttest";
    const file = try std.fs.cwd().createFile("./tmp/persist/invalid_ext/dump_latest_invalid.asdf", .{});
    try file.writeAll(file_content);
    defer file.close();

    try std.testing.expectEqual(persister.load(&storage), error.FileNotFound);

    std.fs.cwd().deleteFile("./tmp/persist/invalid_ext/dump_latest_invalid.asdf") catch {};
    std.fs.cwd().deleteDir("./tmp/persist") catch {};
}

test "should not load corrupted file" {
    std.fs.cwd().makePath("./tmp/persist") catch {};

    var config = try Config.load(std.testing.allocator, null, null);
    defer config.deinit();

    var logger = try log.Logger.init(std.testing.allocator, null);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        "./tmp/persist/corrupted/",
    );
    defer persister.deinit();

    var tracing_allocator = TracingAllocator.init(std.testing.allocator);
    var storage = MemoryStorage.init(tracing_allocator.allocator(), config, &persister);
    defer storage.deinit();

    std.fs.cwd().makeDir("./tmp/persist/corrupted") catch {};

    try std.testing.expectEqual(storage.internal.count(), 0);

    const file_content = "%4\r\n$5test2\r\n$4\r\ntesttest\r\n$5\r\ntest1\r\n$8\r\ntesttest\r\n$5\r\ntest3\r\n$8\r\ntesttest\r\n$5\r\ntest4\r\n$8\r\ntesttest";
    const file = try std.fs.cwd().createFile("./tmp/persist/corrupted/dump_latest_invalid.asdf", .{});
    try file.writeAll(file_content);
    defer file.close();

    try std.testing.expectEqual(persister.load(&storage), error.FileNotFound);

    std.fs.cwd().deleteFile("./tmp/persist/corrupted/dump_latest_invalid.asdf") catch {};
    std.fs.cwd().deleteDir("./tmp/persist") catch {};
}
