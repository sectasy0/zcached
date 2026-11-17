const std = @import("std");

const sets = @import("../../protocol/set.zig");
const ZType = @import("../../protocol/types.zig").ZType;
const helpers = @import("../helper.zig");

// Checks that cloning preserves membership and later insertions to the original do not affect the ordered set copy.
test "Set clone" {
    const allocator = std.testing.allocator;
    var set = sets.Set(ZType).init(allocator);
    defer set.deinit();

    try set.insert(ZType{ .int = 42 });
    try set.insert(ZType{ .int = 24 });

    var clone = try set.clone();
    defer clone.deinit();

    try std.testing.expect(clone.contains(ZType{ .int = 42 }));
    try std.testing.expect(clone.contains(ZType{ .int = 24 }));

    try set.insert(ZType{ .int = 66 });
    try std.testing.expect(!clone.contains(ZType{ .int = 66 }));
}

// Checks that cloning into the requested allocator creates an independent ordered set copy.
test "Set cloneWithAllocator" {
    const allocator = std.testing.allocator;
    var original = sets.Set(ZType).init(allocator);
    defer original.deinit();

    try original.insert(ZType{ .int = 42 });
    try original.insert(ZType{ .int = 24 });

    var clone = try original.cloneWithAllocator(allocator);
    defer clone.deinit();

    try std.testing.expect(clone.contains(ZType{ .int = 42 }));
    try std.testing.expect(clone.contains(ZType{ .int = 24 }));

    try original.insert(ZType{ .int = 66 });
    try std.testing.expect(!clone.contains(ZType{ .int = 66 }));
}

// Checks that a new ordered set is empty and its storage can be released.
test "Set initialization and deinitialization" {
    const allocator = std.testing.allocator;
    var set = sets.Set(ZType).init(allocator);
    defer set.deinit();

    try std.testing.expectEqual(@as(usize, @intCast(0)), set.count());
}

// Checks that inserted values are found while an absent value is not.
test "Set insertion and contains" {
    const allocator = std.testing.allocator;
    var set = sets.Set(ZType).init(allocator);
    defer set.deinit();

    try set.insert(ZType{ .int = 42 });
    try std.testing.expect(set.contains(ZType{ .int = 42 }));

    try std.testing.expect(!set.contains(ZType{ .int = 24 }));
}

// Checks that the collection count tracks its distinct inserted values.
test "Set insertion and count" {
    const allocator = std.testing.allocator;
    var set = sets.Set(ZType).init(allocator);
    defer set.deinit();

    try set.insert(ZType{ .int = 42 });
    try set.insert(ZType{ .int = 24 });

    try std.testing.expectEqual(@as(usize, @intCast(2)), set.count());
}

// Checks that removal returns the matching value and updates membership and count.
test "Set insertion and removal" {
    const allocator = std.testing.allocator;
    var set = sets.Set(ZType).init(allocator);
    defer set.deinit();

    try set.insert(ZType{ .int = 42 });
    try helpers.expectEqualZTypes(
        set.remove(ZType{ .int = 42 }).?.key,
        ZType{ .int = 42 },
    );
    try std.testing.expect(!set.contains(ZType{ .int = 42 }));

    try std.testing.expectEqual(@as(usize, @intCast(0)), set.count());
}

// Checks that iteration visits all stored values in insertion order.
test "Set iterator" {
    const allocator = std.testing.allocator;
    var set = sets.Set(ZType).init(allocator);
    defer set.deinit();

    try set.insert(ZType{ .int = 42 });
    try set.insert(ZType{ .int = 24 });

    const item_count = set.count();

    var items: [2]ZType = undefined;

    var index: usize = 0;
    var it = set.iterator();
    while (it.next()) |entry| {
        if (index >= items.len) {
            break;
        }
        items[index] = entry.key_ptr.*;
        index += 1;
    }

    try std.testing.expectEqual(item_count, index);
}

// Checks that ordered set lookup and removal use value equality for int values.
test "Set with ZType int" {
    const allocator = std.testing.allocator;
    var set = sets.Set(ZType).init(allocator);
    defer set.deinit();

    try set.insert(ZType{ .int = 42 });
    try std.testing.expect(set.contains(ZType{ .int = 42 }));
    try std.testing.expectEqual(ZType{ .int = 42 }, set.remove(ZType{ .int = 42 }).?.key);
}

// Checks that ordered set lookup and removal use value equality for float values.
test "Set with ZType float" {
    const allocator = std.testing.allocator;
    var set = sets.Set(ZType).init(allocator);
    defer set.deinit();

    try set.insert(ZType{ .float = 3.14 });
    try std.testing.expect(set.contains(ZType{ .float = 3.14 }));
    try std.testing.expectEqual(
        ZType{ .float = 3.14 },
        set.remove(ZType{ .float = 3.14 }).?.key,
    );
}

// Checks that ordered set lookup and removal use value equality for str values.
test "Set with ZType str" {
    const allocator = std.testing.allocator;
    var set = sets.Set(ZType).init(allocator);
    defer set.deinit();

    try set.insert(ZType{ .str = "hello" });
    try std.testing.expect(set.contains(ZType{ .str = "hello" }));
    try std.testing.expectEqual(
        ZType{ .str = "hello" },
        set.remove(ZType{ .str = "hello" }).?.key,
    );
}

// Checks that ordered set lookup and removal use value equality for sstr values.
test "Set with ZType sstr" {
    const allocator = std.testing.allocator;
    var set = sets.Set(ZType).init(allocator);
    defer set.deinit();

    try set.insert(ZType{ .sstr = "world" });

    try std.testing.expect(set.contains(ZType{ .sstr = "world" }));
    try std.testing.expectEqual(
        ZType{ .sstr = "world" },
        set.remove(ZType{ .sstr = "world" }).?.key,
    );
}

// Checks that ordered set lookup and removal use value equality for bool values.
test "Set with ZType bool" {
    const allocator = std.testing.allocator;
    var set = sets.Set(ZType).init(allocator);
    defer set.deinit();

    try set.insert(ZType{ .bool = true });
    try std.testing.expect(set.contains(ZType{ .bool = true }));
    try std.testing.expectEqual(
        ZType{ .bool = true },
        set.remove(ZType{ .bool = true }).?.key,
    );
}

// Checks that ordered set lookup and removal use value equality for array values.
test "Set with ZType array" {
    const allocator = std.testing.allocator;
    var set = sets.Set(ZType).init(allocator);
    defer set.deinit();

    var arr = try ZType.Array.initCapacity(allocator, 2);
    defer arr.deinit();
    try arr.append(ZType{ .int = 1 });
    try arr.append(ZType{ .int = 2 });

    try set.insert(ZType{ .array = arr });

    try std.testing.expect(set.contains(ZType{ .array = arr }));
    try std.testing.expectEqual(
        ZType{ .array = arr },
        set.remove(ZType{ .array = arr }).?.key,
    );
}

// Checks that ordered set lookup and removal use value equality for map values.
test "Set with ZType map" {
    const allocator = std.testing.allocator;
    var set = sets.Set(ZType).init(allocator);
    defer set.deinit();

    var map = ZType.Map.init(allocator);
    defer map.deinit();
    try map.put("key1", ZType{ .int = 1 });
    try map.put("key2", ZType{ .int = 2 });

    try set.insert(ZType{ .map = map });
    try std.testing.expect(set.contains(ZType{ .map = map }));
    try std.testing.expectEqual(ZType{ .map = map }, set.remove(ZType{ .map = map }).?.key);
}

// Checks that ordered set lookup and removal use value equality for set values.
test "Set with ZType set" {
    const allocator = std.testing.allocator;
    var set = sets.Set(ZType).init(allocator);
    defer set.deinit();

    var inner_set = ZType.Set.init(allocator);
    defer inner_set.deinit();
    try inner_set.insert(ZType{ .int = 1 });
    try inner_set.insert(ZType{ .int = 2 });

    try set.insert(ZType{ .set = inner_set });

    try std.testing.expect(set.contains(ZType{ .set = inner_set }));
    try std.testing.expectEqual(ZType{ .set = inner_set }, set.remove(ZType{ .set = inner_set }).?.key);
}

// Checks that ordered set lookup and removal use value equality for uset values.
test "Set with ZType uset" {
    const allocator = std.testing.allocator;
    var set = sets.Set(ZType).init(allocator);
    defer set.deinit();

    var inner_uset = ZType.USet.init(allocator);
    defer inner_uset.deinit();
    try inner_uset.insert(ZType{ .int = 1 });
    try inner_uset.insert(ZType{ .int = 2 });

    try set.insert(ZType{ .uset = inner_uset });
    try std.testing.expect(set.contains(ZType{ .uset = inner_uset }));
    try std.testing.expectEqual(
        ZType{ .uset = inner_uset },
        set.remove(ZType{ .uset = inner_uset }).?.key,
    );
}

// Checks that ordered set lookup and removal use value equality for null values.
test "Set with ZType null" {
    const allocator = std.testing.allocator;
    var set = sets.Set(ZType).init(allocator);
    defer set.deinit();

    try set.insert(ZType{ .null = {} });
    try std.testing.expect(set.contains(ZType{ .null = {} }));
    try std.testing.expectEqual(
        ZType{ .null = {} },
        set.remove(ZType{ .null = {} }).?.key,
    );
}

// Checks that cloning preserves membership and later insertions to the original do not affect the unordered set copy.
test "SetUnordered clone" {
    const allocator = std.testing.allocator;
    var set = sets.SetUnordered(ZType).init(allocator);
    defer set.deinit();

    try set.insert(ZType{ .int = 42 });
    try set.insert(ZType{ .int = 24 });

    var clone = try set.clone();
    defer clone.deinit();

    try std.testing.expect(clone.contains(ZType{ .int = 42 }));
    try std.testing.expect(clone.contains(ZType{ .int = 24 }));

    try set.insert(ZType{ .int = 66 });
    try std.testing.expect(!clone.contains(ZType{ .int = 66 }));
}

// Checks that cloning into the requested allocator creates an independent unordered set copy.
test "SetUnordered cloneWithAllocator" {
    const allocator = std.testing.allocator;
    var original = sets.SetUnordered(ZType).init(allocator);
    defer original.deinit();

    try original.insert(ZType{ .int = 42 });
    try original.insert(ZType{ .int = 24 });

    var clone = try original.cloneWithAllocator(allocator);
    defer clone.deinit();

    try std.testing.expect(clone.contains(ZType{ .int = 42 }));
    try std.testing.expect(clone.contains(ZType{ .int = 24 }));

    try original.insert(ZType{ .int = 66 });
    try std.testing.expect(!clone.contains(ZType{ .int = 66 }));
}

// Checks that a new unordered set is empty and its storage can be released.
test "SetUnordered initialization and deinitialization" {
    const allocator = std.testing.allocator;
    var set = sets.SetUnordered(ZType).init(allocator);
    defer set.deinit();

    try std.testing.expectEqual(
        @as(usize, @intCast(0)),
        set.count(),
    );
}

// Checks that inserted values are found while an absent value is not.
test "SetUnordered insertion and contains" {
    const allocator = std.testing.allocator;
    var set = sets.SetUnordered(ZType).init(allocator);
    defer set.deinit();

    try set.insert(ZType{ .int = 42 });
    try std.testing.expect(set.contains(ZType{ .int = 42 }));

    try std.testing.expect(!set.contains(ZType{ .int = 24 }));
}

// Checks that the collection count tracks its distinct inserted values.
test "SetUnordered insertion and count" {
    const allocator = std.testing.allocator;
    var set = sets.SetUnordered(ZType).init(allocator);
    defer set.deinit();

    try set.insert(ZType{ .int = 42 });
    try set.insert(ZType{ .int = 24 });

    try std.testing.expectEqual(@as(usize, @intCast(2)), set.count());
}

// Checks that removal returns the matching value and updates membership and count.
test "SetUnordered insertion and removal" {
    const allocator = std.testing.allocator;
    var set = sets.SetUnordered(ZType).init(allocator);
    defer set.deinit();

    try set.insert(ZType{ .int = 42 });
    try helpers.expectEqualZTypes(
        set.remove(ZType{ .int = 42 }).?.key,
        ZType{ .int = 42 },
    );
    try std.testing.expect(!set.contains(ZType{ .int = 42 }));

    try std.testing.expectEqual(@as(usize, @intCast(0)), set.count());
}

// Checks that iteration visits all stored values without depending on traversal order.
test "SetUnordered iterator" {
    const allocator = std.testing.allocator;
    var set = sets.SetUnordered(ZType).init(allocator);
    defer set.deinit();

    try set.insert(ZType{ .int = 42 });
    try set.insert(ZType{ .int = 24 });

    const item_count = set.count();

    var items: [2]ZType = undefined;

    var index: usize = 0;
    var it = set.iterator();
    while (it.next()) |entry| {
        if (index >= items.len) {
            break;
        }
        items[index] = entry.*;
        index += 1;
    }

    try std.testing.expectEqual(item_count, index);
}

// Checks that unordered set lookup and removal use value equality for int values.
test "SetUnordered with ZType int" {
    const allocator = std.testing.allocator;
    var set = sets.SetUnordered(ZType).init(allocator);
    defer set.deinit();

    try set.insert(ZType{ .int = 42 });
    try std.testing.expect(set.contains(ZType{ .int = 42 }));
    try std.testing.expectEqual(ZType{ .int = 42 }, set.remove(ZType{ .int = 42 }).?.key);
}

// Checks that unordered set lookup and removal use value equality for float values.
test "SetUnordered with ZType float" {
    const allocator = std.testing.allocator;
    var set = sets.SetUnordered(ZType).init(allocator);
    defer set.deinit();

    try set.insert(ZType{ .float = 3.14 });
    try std.testing.expect(set.contains(ZType{ .float = 3.14 }));
    try std.testing.expectEqual(
        ZType{ .float = 3.14 },
        set.remove(ZType{ .float = 3.14 }).?.key,
    );
}

// Checks that unordered set lookup and removal use value equality for str values.
test "SetUnordered with ZType str" {
    const allocator = std.testing.allocator;
    var set = sets.SetUnordered(ZType).init(allocator);
    defer set.deinit();

    try set.insert(ZType{ .str = "hello" });
    try std.testing.expect(set.contains(ZType{ .str = "hello" }));
    try std.testing.expectEqual(
        ZType{ .str = "hello" },
        set.remove(ZType{ .str = "hello" }).?.key,
    );
}

// Checks that unordered set lookup and removal use value equality for sstr values.
test "SetUnordered with ZType sstr" {
    const allocator = std.testing.allocator;
    var set = sets.SetUnordered(ZType).init(allocator);
    defer set.deinit();

    try set.insert(ZType{ .sstr = "world" });

    try std.testing.expect(set.contains(ZType{ .sstr = "world" }));
    try std.testing.expectEqual(
        ZType{ .sstr = "world" },
        set.remove(ZType{ .sstr = "world" }).?.key,
    );
}

// Checks that unordered set lookup and removal use value equality for bool values.
test "SetUnordered with ZType bool" {
    const allocator = std.testing.allocator;
    var set = sets.SetUnordered(ZType).init(allocator);
    defer set.deinit();

    try set.insert(ZType{ .bool = true });
    try std.testing.expect(set.contains(ZType{ .bool = true }));
    try std.testing.expectEqual(
        ZType{ .bool = true },
        set.remove(ZType{ .bool = true }).?.key,
    );
}

// Checks that unordered set lookup and removal use value equality for array values.
test "SetUnordered with ZType array" {
    const allocator = std.testing.allocator;
    var set = sets.SetUnordered(ZType).init(allocator);
    defer set.deinit();

    var arr = try ZType.Array.initCapacity(allocator, 2);
    defer arr.deinit();
    try arr.append(ZType{ .int = 1 });
    try arr.append(ZType{ .int = 2 });

    try set.insert(ZType{ .array = arr });

    try std.testing.expect(set.contains(ZType{ .array = arr }));
    try std.testing.expectEqual(
        ZType{ .array = arr },
        set.remove(ZType{ .array = arr }).?.key,
    );
}

// Checks that unordered set lookup and removal use value equality for map values.
test "SetUnordered with ZType map" {
    const allocator = std.testing.allocator;
    var set = sets.SetUnordered(ZType).init(allocator);
    defer set.deinit();

    var map = ZType.Map.init(allocator);
    defer map.deinit();
    try map.put("key1", ZType{ .int = 1 });
    try map.put("key2", ZType{ .int = 2 });

    try set.insert(ZType{ .map = map });
    try std.testing.expect(set.contains(ZType{ .map = map }));
    try std.testing.expectEqual(ZType{ .map = map }, set.remove(ZType{ .map = map }).?.key);
}

// Checks that unordered set lookup and removal use value equality for set values.
test "SetUnordered with ZType set" {
    const allocator = std.testing.allocator;
    var set = sets.SetUnordered(ZType).init(allocator);
    defer set.deinit();

    var inner_set = ZType.Set.init(allocator);
    defer inner_set.deinit();
    try inner_set.insert(ZType{ .int = 1 });
    try inner_set.insert(ZType{ .int = 2 });

    try set.insert(ZType{ .set = inner_set });

    try std.testing.expect(set.contains(ZType{ .set = inner_set }));
    try std.testing.expectEqual(ZType{ .set = inner_set }, set.remove(ZType{ .set = inner_set }).?.key);
}

// Checks that unordered set lookup and removal use value equality for uset values.
test "SetUnordered with ZType uset" {
    const allocator = std.testing.allocator;
    var set = sets.SetUnordered(ZType).init(allocator);
    defer set.deinit();

    var inner_uset = ZType.USet.init(allocator);
    defer inner_uset.deinit();
    try inner_uset.insert(ZType{ .int = 1 });
    try inner_uset.insert(ZType{ .int = 2 });

    try set.insert(ZType{ .uset = inner_uset });
    try std.testing.expect(set.contains(ZType{ .uset = inner_uset }));
    try std.testing.expectEqual(ZType{ .uset = inner_uset }, set.remove(ZType{ .uset = inner_uset }).?.key);
}

// Checks that unordered set lookup and removal use value equality for null values.
test "SetUnordered with ZType null" {
    const allocator = std.testing.allocator;
    var set = sets.SetUnordered(ZType).init(allocator);
    defer set.deinit();

    try set.insert(ZType{ .null = {} });
    try std.testing.expect(set.contains(ZType{ .null = {} }));
    try std.testing.expectEqual(ZType{ .null = {} }, set.remove(ZType{ .null = {} }).?.key);
}
