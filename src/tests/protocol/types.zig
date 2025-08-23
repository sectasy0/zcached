const std = @import("std");

const types = @import("../../protocol/types.zig");

test "test ztype_copy with int" {
    const original = types.ZType{ .int = 42 };
    var copied = try types.ztype_copy(original, std.testing.allocator);
    defer types.ztype_free(&copied, std.testing.allocator);

    try std.testing.expectEqual(copied.int, original.int);
}

test "test ztype_copy with string" {
    const original = types.ZType{ .str = "Hello, world!" };
    var copied = try types.ztype_copy(original, std.testing.allocator);
    defer types.ztype_free(&copied, std.testing.allocator);

    try std.testing.expectEqualStrings(copied.str, original.str);
}

test "test ztype_copy with array" {
    var array = types.ZType.Array.init(std.testing.allocator);
    defer array.deinit();

    try array.append(types.ZType{ .int = 1 });
    try array.append(types.ZType{ .int = 2 });

    const original = types.ZType{ .array = array };
    var copied = try types.ztype_copy(original, std.testing.allocator);
    defer types.ztype_free(&copied, std.testing.allocator);

    try std.testing.expectEqual(copied.array.items.len, original.array.items.len);

    try std.testing.expectEqual(copied.array.items[0].int, original.array.items[0].int);
    try std.testing.expectEqual(copied.array.items[1].int, original.array.items[1].int);
}

test "test ztype_copy with map" {
    var map = types.ZType.Map.init(std.testing.allocator);
    defer map.deinit();

    try map.put("key1", types.ZType{ .int = 1 });
    try map.put("key2", types.ZType{ .str = "value2" });

    const original = types.ZType{ .map = map };
    var copied = try types.ztype_copy(original, std.testing.allocator);
    defer types.ztype_free(&copied, std.testing.allocator);

    try std.testing.expectEqual(copied.map.get("key1").?.int, 1);
    try std.testing.expectEqualStrings(copied.map.get("key2").?.str, "value2");
}

test "test ztype_copy and ztype_free with set" {
    var set = types.ZType.Set.init(std.testing.allocator);
    defer set.deinit();

    try set.insert(types.ZType{ .int = 1 });
    try set.insert(types.ZType{ .str = "value2" });

    const original = types.ZType{ .set = set };
    var copied = try types.ztype_copy(original, std.testing.allocator);
    defer types.ztype_free(&copied, std.testing.allocator);

    try std.testing.expectEqual(copied.set.contains(types.ZType{ .int = 1 }), true);
    try std.testing.expectEqual(copied.set.contains(types.ZType{ .str = "value2" }), true);
}

test "test ztype_copy and ztype_free with uset" {
    var uset = types.ZType.USet.init(std.testing.allocator);
    defer uset.deinit();

    try uset.insert(types.ZType{ .int = 1 });
    try uset.insert(types.ZType{ .str = "value2" });

    const original = types.ZType{ .uset = uset };
    var copied = try types.ztype_copy(original, std.testing.allocator);
    defer types.ztype_free(&copied, std.testing.allocator);

    try std.testing.expectEqual(copied.uset.contains(types.ZType{ .int = 1 }), true);
    try std.testing.expectEqual(copied.uset.contains(types.ZType{ .str = "value2" }), true);
}

test "test ztype_copy with nested structures" {
    var map = types.ZType.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("nested_key", types.ZType{ .int = 99 });

    var array = types.ZType.Array.init(std.testing.allocator);
    defer array.deinit();
    try array.append(types.ZType{ .map = map });

    const original = types.ZType{ .array = array };
    var copied = try types.ztype_copy(original, std.testing.allocator);
    defer types.ztype_free(&copied, std.testing.allocator);

    try std.testing.expectEqual(copied.array.items.len, original.array.items.len);
    try std.testing.expectEqual(copied.array.items[0].map.get("nested_key").?.int, 99);
}

test "test ztype_free" {
    const original = types.ZType{ .str = "Hello, world!" };
    var copied = try types.ztype_copy(original, std.testing.allocator);
    types.ztype_free(&copied, std.testing.allocator);
    // Ensure the copied value's string is properly freed
    // In Zig, there is no direct way to check if memory is freed.
    // This is more about making sure no crashes occur.
}
