const std = @import("std");

const Deserializer = @import("../../protocol/deserializer.zig").Deserializer;
const types = @import("../../protocol/types.zig");

test "deserialize string" {
    var deserializer = Deserializer.init(std.testing.allocator);
    defer deserializer.deinit();

    const input = types.ZType{ .str = @constCast("hello world") };

    const expected = "$11\r\nhello world\r\n";
    const result = try deserializer.process(input);
    try std.testing.expectEqualStrings(expected, result);
}

test "deserialize empty string" {
    var deserializer = Deserializer.init(std.testing.allocator);
    defer deserializer.deinit();

    const input = types.ZType{ .str = @constCast("") };

    const expected = "$0\r\n\r\n";
    const result = try deserializer.process(input);
    try std.testing.expectEqualStrings(expected, result);
}

test "deserialize int" {
    var deserializer = Deserializer.init(std.testing.allocator);
    defer deserializer.deinit();

    const input = types.ZType{ .int = 123 };

    const expected = ":123\r\n";
    const result = try deserializer.process(input);
    try std.testing.expectEqualStrings(expected, result);
}

test "deserialize bool true" {
    var deserializer = Deserializer.init(std.testing.allocator);
    defer deserializer.deinit();

    const input = types.ZType{ .bool = true };

    const expected = "#t\r\n";
    const result = try deserializer.process(input);
    try std.testing.expectEqualStrings(expected, result);
}

test "deserialize bool false" {
    var deserializer = Deserializer.init(std.testing.allocator);
    defer deserializer.deinit();

    const input = types.ZType{ .bool = false };

    const expected = "#f\r\n";
    const result = try deserializer.process(input);
    try std.testing.expectEqualStrings(expected, result);
}

test "deserialize null" {
    var deserializer = Deserializer.init(std.testing.allocator);
    defer deserializer.deinit();

    const input = types.ZType{ .null = void{} };

    const expected = "_\r\n";
    const result = try deserializer.process(input);
    try std.testing.expectEqualStrings(expected, result);
}

test "deserialize float" {
    var deserializer = Deserializer.init(std.testing.allocator);
    defer deserializer.deinit();

    const input = types.ZType{ .float = 123.456 };

    const expected = ",123.456\r\n";
    const result = try deserializer.process(input);
    try std.testing.expectEqualStrings(expected, result);
}

test "deserialize simple string" {
    var deserializer = Deserializer.init(std.testing.allocator);
    defer deserializer.deinit();

    const input = types.ZType{ .sstr = @constCast("hello world") };

    const expected = "+hello world\r\n";
    const result = try deserializer.process(input);
    try std.testing.expectEqualStrings(expected, result);
}

test "deserialize array" {
    var array = std.ArrayList(types.ZType).init(std.testing.allocator);
    defer array.deinit();

    try array.append(.{ .str = @constCast("first") });
    try array.append(.{ .str = @constCast("second") });
    try array.append(.{ .str = @constCast("third") });

    var deserializer = Deserializer.init(std.testing.allocator);
    defer deserializer.deinit();

    const value = types.ZType{ .array = array };

    const result = try deserializer.process(value);
    const expected = "*3\r\n$5\r\nfirst\r\n$6\r\nsecond\r\n$5\r\nthird\r\n";
    try std.testing.expectEqualStrings(expected, result);
}

test "serialize map" {
    var map = std.StringHashMap(types.ZType).init(std.testing.allocator);
    defer map.deinit();

    try map.put("a", .{ .str = @constCast("first") });
    try map.put("b", .{ .str = @constCast("second") });
    try map.put("c", .{ .str = @constCast("third") });

    var deserializer = Deserializer.init(std.testing.allocator);
    defer deserializer.deinit();

    const value = types.ZType{ .map = map };

    const result = try deserializer.process(value);
    // it's not guaranteed that the order of the map will be the same
    const expected = "%3\r\n$1\r\nb\r\n$6\r\nsecond\r\n$1\r\na\r\n$5\r\nfirst\r\n$1\r\nc\r\n$5\r\nthird\r\n";
    try std.testing.expectEqualStrings(expected, result);
}

test "serialize set" {
    var set = types.sets.Set(types.ZType).init(std.testing.allocator);
    defer set.deinit();

    try set.insert(.{ .str = @constCast("first") });
    try set.insert(.{ .str = @constCast("second") });
    try set.insert(.{ .str = @constCast("third") });

    var deserializer = Deserializer.init(std.testing.allocator);
    defer deserializer.deinit();

    const value = types.ZType{ .set = set };

    const result = try deserializer.process(value);
    // it's guaranteed that the order of the set will be the same
    const expected = "~3\r\n$5\r\nfirst\r\n$6\r\nsecond\r\n$5\r\nthird\r\n";
    try std.testing.expectEqualStrings(expected, result);
}

test "serialize uset" {
    var uset = types.sets.SetUnordered(types.ZType).init(std.testing.allocator);
    defer uset.deinit();

    try uset.insert(.{ .str = @constCast("first") });
    try uset.insert(.{ .str = @constCast("second") });
    try uset.insert(.{ .str = @constCast("third") });

    var deserializer = Deserializer.init(std.testing.allocator);
    defer deserializer.deinit();

    const value = types.ZType{ .uset = uset };

    const result = try deserializer.process(value);
    // it's not guaranteed that the order of the uset will be the same
    const expected = "/3\r\n$5\r\nfirst\r\n$5\r\nthird\r\n$6\r\nsecond\r\n";
    try std.testing.expectEqualStrings(expected, result);
}
