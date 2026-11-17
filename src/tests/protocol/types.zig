const std = @import("std");

const types = @import("../../protocol/types.zig");

// Uses allocation-failure injection to ensure partially copied nested values are released on error.
test "snapshot copying releases partial nested values on allocation failure" {
    var array = try types.ZType.Array.initCapacity(std.testing.allocator, 2);
    defer array.deinit();
    try array.appendSlice(&.{ .{ .str = "first" }, .{ .str = "second" } });
    var map = types.ZType.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("nested", .{ .array = array });
    try map.put("other", .{ .str = "value" });
    const Case = struct {
        fn run(allocator: std.mem.Allocator, value: types.ZType) !void {
            var copied = try types.ztype_copy(value, allocator);
            defer types.ztype_free(&copied, allocator);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{types.ZType{ .map = map }});
}

// Verifies scalar copying preserves an integer value without changing its meaning.
test "test ztype_copy with int" {
    const original = types.ZType{ .int = 42 };
    var copied = try types.ztype_copy(original, std.testing.allocator);
    defer types.ztype_free(&copied, std.testing.allocator);

    try std.testing.expectEqual(copied.int, original.int);
}

// Verifies string copying preserves contents and can be freed with the destination allocator.
test "test ztype_copy with string" {
    const original = types.ZType{ .str = "Hello, world!" };
    var copied = try types.ztype_copy(original, std.testing.allocator);
    defer types.ztype_free(&copied, std.testing.allocator);

    try std.testing.expectEqualStrings(copied.str, original.str);
}

// Checks recursive copying of array elements and their order.
test "test ztype_copy with array" {
    var array = try types.ZType.Array.initCapacity(std.testing.allocator, 2);
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

// Checks recursive copying of string keys and mixed map values.
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

// Checks that copying and freeing an ordered set preserves its members.
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

// Checks that copying and freeing an unordered set preserves its members.
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

// Verifies a nested map remains accessible after recursively copying its containing array.
test "test ztype_copy with nested structures" {
    var map = types.ZType.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("nested_key", types.ZType{ .int = 99 });

    var array = try types.ZType.Array.initCapacity(std.testing.allocator, 1);
    defer array.deinit();
    try array.append(types.ZType{ .map = map });

    const original = types.ZType{ .array = array };
    var copied = try types.ztype_copy(original, std.testing.allocator);
    defer types.ztype_free(&copied, std.testing.allocator);

    try std.testing.expectEqual(copied.array.items.len, original.array.items.len);
    try std.testing.expectEqual(copied.array.items[0].map.get("nested_key").?.int, 99);
}

// Exercises recursive cleanup of an allocated string value without a crash.
test "test ztype_free" {
    const original = types.ZType{ .str = "Hello, world!" };
    var copied = try types.ztype_copy(original, std.testing.allocator);
    types.ztype_free(&copied, std.testing.allocator);
    // Ensure the copied value's string is properly freed
    // In Zig, there is no direct way to check if memory is freed.
    // This is more about making sure no crashes occur.
}
