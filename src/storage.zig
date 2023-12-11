const std = @import("std");
const AnyType = @import("protocol/types.zig").AnyType;

pub const MemoryStorage = struct {
    internal: std.StringHashMap(AnyType),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MemoryStorage {
        return MemoryStorage{
            .internal = std.StringHashMap(AnyType).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn put(self: *MemoryStorage, key: []const u8, value: AnyType) !void {
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
    var allocator = std.heap.page_allocator;
    var storage = MemoryStorage.init(allocator);
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
    var allocator = std.heap.page_allocator;
    var storage = MemoryStorage.init(allocator);
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
    var allocator = std.heap.page_allocator;
    var storage = MemoryStorage.init(allocator);
    defer storage.deinit();

    try std.testing.expectEqual(storage.delete("foo"), false);
}

test "should flush storage" {
    var allocator = std.heap.page_allocator;
    var storage = MemoryStorage.init(allocator);
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
    var allocator = std.heap.page_allocator;
    var storage = MemoryStorage.init(allocator);
    defer storage.deinit();

    const err_value = .{ .err = .{ .message = "random error" } };
    try std.testing.expectEqual(storage.put("test", err_value), error.CantInsertError);
}
