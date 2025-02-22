const std = @import("std");

const sets = @import("../../protocol/types/sets.zig");
const ZType = @import("../../protocol/types.zig").ZType;
const helpers = @import("../helper.zig");

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

test "Set initialization and deinitialization" {
    const allocator = std.testing.allocator;
    var set = sets.Set(ZType).init(allocator);
    defer set.deinit();

    try std.testing.expectEqual(@as(usize, @intCast(0)), set.count());
}

test "Set insertion and contains" {
    const allocator = std.testing.allocator;
    var set = sets.Set(ZType).init(allocator);
    defer set.deinit();

    try set.insert(ZType{ .int = 42 });
    try std.testing.expect(set.contains(ZType{ .int = 42 }));

    try std.testing.expect(!set.contains(ZType{ .int = 24 }));
}

test "Set insertion and count" {
    const allocator = std.testing.allocator;
    var set = sets.Set(ZType).init(allocator);
    defer set.deinit();

    try set.insert(ZType{ .int = 42 });
    try set.insert(ZType{ .int = 24 });

    try std.testing.expectEqual(@as(usize, @intCast(2)), set.count());
}

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

test "Set with ZType int" {
    const allocator = std.testing.allocator;
    var set = sets.Set(ZType).init(allocator);
    defer set.deinit();

    try set.insert(ZType{ .int = 42 });
    try std.testing.expect(set.contains(ZType{ .int = 42 }));
    try std.testing.expectEqual(ZType{ .int = 42 }, set.remove(ZType{ .int = 42 }).?.key);
}

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

test "Set with ZType str" {
    const allocator = std.testing.allocator;
    var set = sets.Set(ZType).init(allocator);
    defer set.deinit();

    try set.insert(ZType{ .str = @constCast("hello") });
    try std.testing.expect(set.contains(ZType{ .str = @constCast("hello") }));
    try std.testing.expectEqual(
        ZType{ .str = @constCast("hello") },
        set.remove(ZType{ .str = @constCast("hello") }).?.key,
    );
}

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

test "Set with ZType array" {
    const allocator = std.testing.allocator;
    var set = sets.Set(ZType).init(allocator);
    defer set.deinit();

    var arr = ZType.array.init(allocator);
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

test "Set with ZType map" {
    const allocator = std.testing.allocator;
    var set = sets.Set(ZType).init(allocator);
    defer set.deinit();

    var map = ZType.map.init(allocator);
    defer map.deinit();
    try map.put("key1", ZType{ .int = 1 });
    try map.put("key2", ZType{ .int = 2 });

    try set.insert(ZType{ .map = map });
    try std.testing.expect(set.contains(ZType{ .map = map }));
    try std.testing.expectEqual(ZType{ .map = map }, set.remove(ZType{ .map = map }).?.key);
}

test "Set with ZType set" {
    const allocator = std.testing.allocator;
    var set = sets.Set(ZType).init(allocator);
    defer set.deinit();

    var inner_set = ZType.set.init(allocator);
    defer inner_set.deinit();
    try inner_set.insert(ZType{ .int = 1 });
    try inner_set.insert(ZType{ .int = 2 });

    try set.insert(ZType{ .set = inner_set });

    try std.testing.expect(set.contains(ZType{ .set = inner_set }));
    try std.testing.expectEqual(ZType{ .set = inner_set }, set.remove(ZType{ .set = inner_set }).?.key);
}

test "Set with ZType uset" {
    const allocator = std.testing.allocator;
    var set = sets.Set(ZType).init(allocator);
    defer set.deinit();

    var inner_uset = ZType.uset.init(allocator);
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

test "SetUnordered initialization and deinitialization" {
    const allocator = std.testing.allocator;
    var set = sets.SetUnordered(ZType).init(allocator);
    defer set.deinit();

    try std.testing.expectEqual(
        @as(usize, @intCast(0)),
        set.count(),
    );
}

test "SetUnordered insertion and contains" {
    const allocator = std.testing.allocator;
    var set = sets.SetUnordered(ZType).init(allocator);
    defer set.deinit();

    try set.insert(ZType{ .int = 42 });
    try std.testing.expect(set.contains(ZType{ .int = 42 }));

    try std.testing.expect(!set.contains(ZType{ .int = 24 }));
}

test "SetUnordered insertion and count" {
    const allocator = std.testing.allocator;
    var set = sets.SetUnordered(ZType).init(allocator);
    defer set.deinit();

    try set.insert(ZType{ .int = 42 });
    try set.insert(ZType{ .int = 24 });

    try std.testing.expectEqual(@as(usize, @intCast(2)), set.count());
}

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

test "SetUnordered with ZType int" {
    const allocator = std.testing.allocator;
    var set = sets.SetUnordered(ZType).init(allocator);
    defer set.deinit();

    try set.insert(ZType{ .int = 42 });
    try std.testing.expect(set.contains(ZType{ .int = 42 }));
    try std.testing.expectEqual(ZType{ .int = 42 }, set.remove(ZType{ .int = 42 }).?.key);
}

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

test "SetUnordered with ZType str" {
    const allocator = std.testing.allocator;
    var set = sets.SetUnordered(ZType).init(allocator);
    defer set.deinit();

    try set.insert(ZType{ .str = @constCast("hello") });
    try std.testing.expect(set.contains(ZType{ .str = @constCast("hello") }));
    try std.testing.expectEqual(
        ZType{ .str = @constCast("hello") },
        set.remove(ZType{ .str = @constCast("hello") }).?.key,
    );
}

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

test "SetUnordered with ZType array" {
    const allocator = std.testing.allocator;
    var set = sets.SetUnordered(ZType).init(allocator);
    defer set.deinit();

    var arr = ZType.array.init(allocator);
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

test "SetUnordered with ZType map" {
    const allocator = std.testing.allocator;
    var set = sets.SetUnordered(ZType).init(allocator);
    defer set.deinit();

    var map = ZType.map.init(allocator);
    defer map.deinit();
    try map.put("key1", ZType{ .int = 1 });
    try map.put("key2", ZType{ .int = 2 });

    try set.insert(ZType{ .map = map });
    try std.testing.expect(set.contains(ZType{ .map = map }));
    try std.testing.expectEqual(ZType{ .map = map }, set.remove(ZType{ .map = map }).?.key);
}

test "SetUnordered with ZType set" {
    const allocator = std.testing.allocator;
    var set = sets.SetUnordered(ZType).init(allocator);
    defer set.deinit();

    var inner_set = ZType.set.init(allocator);
    defer inner_set.deinit();
    try inner_set.insert(ZType{ .int = 1 });
    try inner_set.insert(ZType{ .int = 2 });

    try set.insert(ZType{ .set = inner_set });

    try std.testing.expect(set.contains(ZType{ .set = inner_set }));
    try std.testing.expectEqual(ZType{ .set = inner_set }, set.remove(ZType{ .set = inner_set }).?.key);
}

test "SetUnordered with ZType uset" {
    const allocator = std.testing.allocator;
    var set = sets.SetUnordered(ZType).init(allocator);
    defer set.deinit();

    var inner_uset = ZType.uset.init(allocator);
    defer inner_uset.deinit();
    try inner_uset.insert(ZType{ .int = 1 });
    try inner_uset.insert(ZType{ .int = 2 });

    try set.insert(ZType{ .uset = inner_uset });
    try std.testing.expect(set.contains(ZType{ .uset = inner_uset }));
    try std.testing.expectEqual(ZType{ .uset = inner_uset }, set.remove(ZType{ .uset = inner_uset }).?.key);
}

test "SetUnordered with ZType null" {
    const allocator = std.testing.allocator;
    var set = sets.SetUnordered(ZType).init(allocator);
    defer set.deinit();

    try set.insert(ZType{ .null = {} });
    try std.testing.expect(set.contains(ZType{ .null = {} }));
    try std.testing.expectEqual(ZType{ .null = {} }, set.remove(ZType{ .null = {} }).?.key);
}
