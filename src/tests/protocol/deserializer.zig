const std = @import("std");

const Deserializer = @import("../../protocol/deserializer.zig").Deserializer;
const types = @import("../../protocol/types.zig");

// Verifies bulk-string length framing and payload bytes in the encoded result.
test "deserialize string" {
    var deserializer = Deserializer.init(std.testing.allocator);
    defer deserializer.deinit();

    const input = types.ZType{ .str = "hello world" };

    const expected = "$11\r\nhello world\r\n";
    const result = try deserializer.process(input);
    try std.testing.expectEqualStrings(expected, result);
}

// Checks that empty bulk strings are encoded with a zero length and empty payload.
test "deserialize empty string" {
    var deserializer = Deserializer.init(std.testing.allocator);
    defer deserializer.deinit();

    const input = types.ZType{ .str = "" };

    const expected = "$0\r\n\r\n";
    const result = try deserializer.process(input);
    try std.testing.expectEqualStrings(expected, result);
}

// Checks the integer marker and decimal representation for a scalar value.
test "deserialize int" {
    var deserializer = Deserializer.init(std.testing.allocator);
    defer deserializer.deinit();

    const input = types.ZType{ .int = 123 };

    const expected = ":123\r\n";
    const result = try deserializer.process(input);
    try std.testing.expectEqualStrings(expected, result);
}

// Checks that true uses the protocol true marker.
test "deserialize bool true" {
    var deserializer = Deserializer.init(std.testing.allocator);
    defer deserializer.deinit();

    const input = types.ZType{ .bool = true };

    const expected = "#t\r\n";
    const result = try deserializer.process(input);
    try std.testing.expectEqualStrings(expected, result);
}

// Checks that false uses the protocol false marker.
test "deserialize bool false" {
    var deserializer = Deserializer.init(std.testing.allocator);
    defer deserializer.deinit();

    const input = types.ZType{ .bool = false };

    const expected = "#f\r\n";
    const result = try deserializer.process(input);
    try std.testing.expectEqualStrings(expected, result);
}

// Checks the protocol null marker and its line ending.
test "deserialize null" {
    var deserializer = Deserializer.init(std.testing.allocator);
    defer deserializer.deinit();

    const input = types.ZType{ .null = {} };

    const expected = "_\r\n";
    const result = try deserializer.process(input);
    try std.testing.expectEqualStrings(expected, result);
}

// Checks that a floating-point scalar is encoded with its numeric value.
test "deserialize float" {
    var deserializer = Deserializer.init(std.testing.allocator);
    defer deserializer.deinit();

    const input = types.ZType{ .float = 123.456 };

    const expected = ",123.456\r\n";
    const result = try deserializer.process(input);
    try std.testing.expectEqualStrings(expected, result);
}

// Checks that simple strings use their distinct response marker.
test "deserialize simple string" {
    var deserializer = Deserializer.init(std.testing.allocator);
    defer deserializer.deinit();

    const input = types.ZType{ .sstr = "hello world" };

    const expected = "+hello world\r\n";
    const result = try deserializer.process(input);
    try std.testing.expectEqualStrings(expected, result);
}

// Verifies an array header and recursively encoded elements preserve sequence order.
test "deserialize array" {
    var array = try std.array_list.Managed(types.ZType).initCapacity(std.testing.allocator, 3);
    defer array.deinit();

    try array.append(.{ .str = "first" });
    try array.append(.{ .str = "second" });
    try array.append(.{ .str = "third" });

    var deserializer = Deserializer.init(std.testing.allocator);
    defer deserializer.deinit();

    const value = types.ZType{ .array = array };

    const result = try deserializer.process(value);
    const expected = "*3\r\n$5\r\nfirst\r\n$6\r\nsecond\r\n$5\r\nthird\r\n";
    try std.testing.expectEqualStrings(expected, result);
    try std.testing.expectEqual(result.len, try Deserializer.encodedLen(value));
}

// Guards against excessive temporary allocations by encoding a large array with a bounded allocator.
test "large array encoding uses linear output storage" {
    var backing: [128 * 1024]u8 = undefined;
    var buffer_allocator = std.heap.FixedBufferAllocator.init(&backing);
    var deserializer = Deserializer.init(buffer_allocator.allocator());
    defer deserializer.deinit();
    const items: [512]types.ZType = @splat(.{ .str = "abcdefghijklmnopqrst" });
    var array = try types.ZType.Array.initCapacity(std.testing.allocator, items.len);
    defer array.deinit();
    try array.appendSlice(&items);
    const bytes = try deserializer.process(.{ .array = array });
    try std.testing.expectStringStartsWith(bytes, "*512\r\n");
    try std.testing.expectEqual(@as(usize, 512), std.mem.count(u8, bytes, "$20\r\nabcdefghijklmnopqrst\r\n"));
    try std.testing.expectEqual(@as(usize, 6 + 512 * 27), bytes.len);
}
// Checks map entry framing and key/value encoding for the populated map.
test "serialize map" {
    var map = std.StringHashMap(types.ZType).init(std.testing.allocator);
    defer map.deinit();

    try map.put("a", .{ .str = "first" });
    try map.put("b", .{ .str = "second" });
    try map.put("c", .{ .str = "third" });

    var deserializer = Deserializer.init(std.testing.allocator);
    defer deserializer.deinit();

    const value = types.ZType{ .map = map };

    const result = try deserializer.process(value);
    // it's not guaranteed that the order of the map will be the same
    const expected = "%3\r\n$1\r\nb\r\n$6\r\nsecond\r\n$1\r\na\r\n$5\r\nfirst\r\n$1\r\nc\r\n$5\r\nthird\r\n";
    try std.testing.expectEqualStrings(expected, result);
    try std.testing.expectEqual(result.len, try Deserializer.encodedLen(value));
}

// Verifies ordered-set entries are emitted in insertion order.
test "serialize set" {
    var set = types.sets.Set(types.ZType).init(std.testing.allocator);
    defer set.deinit();

    try set.insert(.{ .str = "first" });
    try set.insert(.{ .str = "second" });
    try set.insert(.{ .str = "third" });

    var deserializer = Deserializer.init(std.testing.allocator);
    defer deserializer.deinit();

    const value = types.ZType{ .set = set };

    const result = try deserializer.process(value);
    // it's guaranteed that the order of the set will be the same
    const expected = "/3\r\n$5\r\nfirst\r\n$6\r\nsecond\r\n$5\r\nthird\r\n";
    try std.testing.expectEqualStrings(expected, result);
    try std.testing.expectEqual(result.len, try Deserializer.encodedLen(value));
}

// Checks unordered-set framing and its entries without assuming iteration order.
test "serialize uset" {
    var uset = types.sets.SetUnordered(types.ZType).init(std.testing.allocator);
    defer uset.deinit();

    try uset.insert(.{ .str = "first" });
    try uset.insert(.{ .str = "second" });
    try uset.insert(.{ .str = "third" });

    var deserializer = Deserializer.init(std.testing.allocator);
    defer deserializer.deinit();

    const value = types.ZType{ .uset = uset };

    const result = try deserializer.process(value);
    // it's not guaranteed that the order of the uset will be the same
    const expected = "~3\r\n$5\r\nfirst\r\n$5\r\nthird\r\n$6\r\nsecond\r\n";
    try std.testing.expectEqualStrings(expected, result);
    try std.testing.expectEqual(result.len, try Deserializer.encodedLen(value));
}
