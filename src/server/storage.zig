const std = @import("std");

const Config = @import("config.zig").Config;
const AnyType = @import("../protocol/types.zig").AnyType;
const TracingAllocator = @import("tracing.zig").TracingAllocator;

const ptrCast = @import("utils.zig").ptrCast;

pub const MemoryStorage = struct {
    internal: std.StringHashMap(AnyType),
    tracing_allocator: std.mem.Allocator,

    config: Config,

    pub fn init(tracing_allocator: std.mem.Allocator, config: Config) MemoryStorage {
        return MemoryStorage{
            .internal = std.StringHashMap(AnyType).init(tracing_allocator),
            .tracing_allocator = tracing_allocator,
            .config = config,
        };
    }

    pub fn put(self: *MemoryStorage, key: []const u8, value: AnyType) !void {
        const tracking = ptrCast(TracingAllocator, self.tracing_allocator.ptr);

        if (tracking.real_size >= self.config.max_memory and self.config.max_memory != 0) {
            return error.MemoryLimitExceeded;
        }

        switch (value) {
            AnyType.err => return error.CantInsertError,
            else => self.internal.put(key, value) catch return error.InsertFailure,
        }
    }

    pub fn get(self: *MemoryStorage, key: []const u8) !AnyType {
        const value = self.internal.get(key);
        if (value == null) return error.NotFound;
        return value.?;
    }

    pub fn delete(self: *MemoryStorage, key: []const u8) bool {
        return self.internal.remove(key);
    }

    pub fn flush(self: *MemoryStorage) void {
        self.internal.clearRetainingCapacity();
    }

    pub fn deinit(self: *MemoryStorage) void {
        self.internal.deinit();
    }
};

test "should get existing and non-existing key" {
    var config = try Config.load(std.testing.allocator, null, null);
    defer config.deinit();

    var tracing_allocator = TracingAllocator.init(std.testing.allocator);
    var storage = MemoryStorage.init(tracing_allocator.allocator(), config);
    defer storage.deinit();

    var string = "Was wir wissen, ist ein Tropfen, was wir nicht wissen, ein Ozean.";
    var value: AnyType = .{ .str = @constCast(string) };

    try storage.put("foo", .{ .int = 42 });
    try storage.put("bar", value);

    try std.testing.expectEqual(storage.get("foo"), .{ .int = 42 });
    try std.testing.expectEqual(storage.get("bar"), value);
    try std.testing.expectEqual(storage.get("baz"), error.NotFound);
}

test "should delete existing key" {
    var config = try Config.load(std.testing.allocator, null, null);
    defer config.deinit();

    var tracing_allocator = TracingAllocator.init(std.testing.allocator);
    var storage = MemoryStorage.init(tracing_allocator.allocator(), config);
    defer storage.deinit();

    var string = "Die meisten Menschen sind nichts als Bauern auf einem Schachbrett, das von einer unbekannten Hand geführt wird.";
    var value: AnyType = .{ .str = @constCast(string) };

    try storage.put("foo", .{ .int = 42 });
    try storage.put("bar", value);

    try std.testing.expectEqual(storage.delete("foo"), true);
    try std.testing.expectEqual(storage.get("foo"), error.NotFound);
    try std.testing.expectEqual(storage.get("bar"), value);
}

test "should delete non-existing key" {
    var config = try Config.load(std.testing.allocator, null, null);
    defer config.deinit();

    var tracing_allocator = TracingAllocator.init(std.testing.allocator);
    var storage = MemoryStorage.init(tracing_allocator.allocator(), config);
    defer storage.deinit();

    try std.testing.expectEqual(storage.delete("foo"), false);
}

test "should flush storage" {
    var config = try Config.load(std.testing.allocator, null, null);
    defer config.deinit();

    var tracing_allocator = TracingAllocator.init(std.testing.allocator);
    var storage = MemoryStorage.init(tracing_allocator.allocator(), config);
    defer storage.deinit();

    var string = "Es gibt Momente im Leben, da muss man verstehen, dass die Entscheidungen, die man trifft, nicht nur das eigene Schicksal angehen.";
    var value: AnyType = .{
        .str = @constCast(string),
    };

    try storage.put("foo", .{ .int = 42 });
    try storage.put("bar", value);

    storage.flush();

    try std.testing.expectEqual(storage.get("foo"), error.NotFound);
    try std.testing.expectEqual(storage.get("bar"), error.NotFound);
}

test "should not store error" {
    var config = try Config.load(std.testing.allocator, null, null);
    defer config.deinit();

    var tracing_allocator = TracingAllocator.init(std.testing.allocator);
    var storage = MemoryStorage.init(tracing_allocator.allocator(), config);
    defer storage.deinit();

    const err_value = .{ .err = .{ .message = "random error" } };
    try std.testing.expectEqual(storage.put("test", err_value), error.CantInsertError);
}

test "should return error.MemoryLimitExceeded" {
    var config = try Config.load(std.testing.allocator, null, null);
    defer config.deinit();
    config.max_memory = 1048576; // 1 megabyte

    var tracing_allocator = TracingAllocator.init(std.testing.allocator);
    var storage = MemoryStorage.init(tracing_allocator.allocator(), config);
    defer storage.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var string = "Was wir wissen, ist ein Tropfen, was wir nicht wissen, ein Ozean.";
    var value: AnyType = .{ .str = @constCast(string) };
    for (0..6554) |i| {
        var key = try std.fmt.allocPrint(arena.allocator(), "key-{d}", .{i});
        try storage.put(key, value);
    }

    try std.testing.expectEqual(storage.put("test key", value), error.MemoryLimitExceeded);
}
