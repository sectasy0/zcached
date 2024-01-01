const os = @import("std").os;
const std = @import("std");

const types = @import("types.zig");

pub const Deserializer = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) Deserializer {
        return Deserializer{
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Deserializer) void {
        self.arena.deinit();
    }

    pub fn process(self: *Deserializer, input: types.AnyType) anyerror![]const u8 {
        switch (input) {
            .str => return try self.deserialize_str(input),
            .sstr => return try self.deserialize_sstr(input),
            .int => return try self.deserialize_int(input),
            .bool => return try self.deserialize_bool(input),
            .null => return try self.deserialize_null(input),
            .array => return try self.deserialize_array(input),
            .float => return try self.deserialize_float(input),
            .map => return try self.deserialize_map(input),
            else => return error.UnsuportedType,
        }
    }

    fn deserialize_str(self: *Deserializer, input: types.AnyType) ![]const u8 {
        const bytes = std.fmt.allocPrint(
            self.arena.allocator(),
            "${d}\r\n{s}\r\n",
            .{ input.str.len, input.str },
        ) catch {
            return error.DeserializationError;
        };
        return bytes;
    }

    fn deserialize_sstr(self: *Deserializer, input: types.AnyType) ![]const u8 {
        const bytes = std.fmt.allocPrint(
            self.arena.allocator(),
            "+{s}\r\n",
            .{input.sstr},
        ) catch {
            return error.DeserializationError;
        };
        return bytes;
    }

    fn deserialize_int(self: *Deserializer, input: types.AnyType) ![]const u8 {
        const bytes = std.fmt.allocPrint(
            self.arena.allocator(),
            ":{d}\r\n",
            .{input.int},
        ) catch {
            return error.DeserializationError;
        };
        return bytes;
    }

    fn deserialize_bool(self: *Deserializer, input: types.AnyType) ![]const u8 {
        var bool_byte: [1]u8 = undefined;
        if (input.bool) {
            bool_byte = @constCast("t").*;
        } else {
            bool_byte = @constCast("f").*;
        }
        const bytes = std.fmt.allocPrint(
            self.arena.allocator(),
            "#{s}\r\n",
            .{bool_byte},
        ) catch {
            return error.DeserializationError;
        };
        return bytes;
    }

    fn deserialize_null(self: *Deserializer, input: types.AnyType) ![]const u8 {
        _ = input;
        _ = self;
        return "_\r\n";
    }

    fn deserialize_error(self: *Deserializer, input: types.AnyType) ![]const u8 {
        const bytes = std.fmt.allocPrint(
            self.arena.allocator(),
            "-{s}\r\n",
            .{input.err.message},
        ) catch {
            return error.DeserializationError;
        };
        return bytes;
    }

    fn deserialize_float(self: *Deserializer, input: types.AnyType) ![]const u8 {
        const bytes = std.fmt.allocPrint(
            self.arena.allocator(),
            ",{d}\r\n",
            .{input.float},
        ) catch {
            return error.DeserializationError;
        };
        return bytes;
    }

    fn deserialize_array(self: *Deserializer, input: types.AnyType) ![]const u8 {
        var result: []u8 = undefined;

        const array_prefix = std.fmt.allocPrint(
            self.arena.allocator(),
            "*{d}\r\n",
            .{input.array.items.len},
        ) catch {
            return error.DeserializationError;
        };

        result = array_prefix;

        for (input.array.items) |item| {
            var bytes = try self.process(item);
            const res = try std.mem.concat(
                self.arena.allocator(),
                u8,
                &.{ result, bytes },
            );
            result = res;
        }
        return result;
    }

    fn deserialize_map(self: *Deserializer, input: types.AnyType) ![]const u8 {
        var result: []u8 = undefined;

        const map_prefix = std.fmt.allocPrint(
            self.arena.allocator(),
            "%{d}\r\n",
            .{input.map.count()},
        ) catch {
            return error.DeserializationError;
        };

        result = map_prefix;

        var iterator = input.map.iterator();
        while (iterator.next()) |item| {
            var bytes = try self.process(.{ .sstr = @constCast(item.key_ptr.*) });
            const key_part = try std.mem.concat(
                self.arena.allocator(),
                u8,
                &.{ result, bytes },
            );
            result = key_part;

            bytes = try self.process(item.value_ptr.*);
            const value_part = try std.mem.concat(
                self.arena.allocator(),
                u8,
                &.{ result, bytes },
            );
            result = value_part;
        }
        return result;
    }
};

test "deserialize string" {
    var deserializer = Deserializer.init(std.testing.allocator);
    defer deserializer.deinit();

    const input = types.AnyType{ .str = @constCast("hello world") };

    const expected = "$11\r\nhello world\r\n";
    const result = try deserializer.process(input);
    try std.testing.expectEqualStrings(expected, result);
}

test "deserialize empty string" {
    var deserializer = Deserializer.init(std.testing.allocator);
    defer deserializer.deinit();

    const input = types.AnyType{ .str = @constCast("") };

    const expected = "$0\r\n\r\n";
    const result = try deserializer.process(input);
    try std.testing.expectEqualStrings(expected, result);
}

test "deserialize int" {
    var deserializer = Deserializer.init(std.testing.allocator);
    defer deserializer.deinit();

    const input = types.AnyType{ .int = 123 };

    const expected = ":123\r\n";
    const result = try deserializer.process(input);
    try std.testing.expectEqualStrings(expected, result);
}

test "deserialize bool true" {
    var deserializer = Deserializer.init(std.testing.allocator);
    defer deserializer.deinit();

    const input = types.AnyType{ .bool = true };

    const expected = "#t\r\n";
    const result = try deserializer.process(input);
    try std.testing.expectEqualStrings(expected, result);
}

test "deserialize bool false" {
    var deserializer = Deserializer.init(std.testing.allocator);
    defer deserializer.deinit();

    const input = types.AnyType{ .bool = false };

    const expected = "#f\r\n";
    const result = try deserializer.process(input);
    try std.testing.expectEqualStrings(expected, result);
}

test "deserialize null" {
    var deserializer = Deserializer.init(std.testing.allocator);
    defer deserializer.deinit();

    const input = types.AnyType{ .null = void{} };

    const expected = "_\r\n";
    const result = try deserializer.process(input);
    try std.testing.expectEqualStrings(expected, result);
}

test "deserialize float" {
    var deserializer = Deserializer.init(std.testing.allocator);
    defer deserializer.deinit();

    const input = types.AnyType{ .float = 123.456 };

    const expected = ",123.456\r\n";
    const result = try deserializer.process(input);
    try std.testing.expectEqualStrings(expected, result);
}

test "deserialize simple string" {
    var deserializer = Deserializer.init(std.testing.allocator);
    defer deserializer.deinit();

    const input = types.AnyType{ .sstr = @constCast("hello world") };

    const expected = "+hello world\r\n";
    const result = try deserializer.process(input);
    try std.testing.expectEqualStrings(expected, result);
}

test "deserialize array" {
    var array = std.ArrayList(types.AnyType).init(std.testing.allocator);
    defer array.deinit();

    try array.append(.{ .str = @constCast("first") });
    try array.append(.{ .str = @constCast("second") });
    try array.append(.{ .str = @constCast("third") });

    var deserializer = Deserializer.init(std.testing.allocator);
    defer deserializer.deinit();

    var value = types.AnyType{ .array = array };

    var result = try deserializer.process(value);
    const expected = "*3\r\n$5\r\nfirst\r\n$6\r\nsecond\r\n$5\r\nthird\r\n";
    try std.testing.expectEqualStrings(expected, result);
}

test "serialize map" {
    var map = std.StringHashMap(types.AnyType).init(std.testing.allocator);
    defer map.deinit();

    try map.put("a", .{ .str = @constCast("first") });
    try map.put("b", .{ .str = @constCast("second") });
    try map.put("c", .{ .str = @constCast("third") });

    var deserializer = Deserializer.init(std.testing.allocator);
    defer deserializer.deinit();

    var value = types.AnyType{ .map = map };

    var result = try deserializer.process(value);
    // it's not guaranteed that the order of the map will be the same
    const expected = "%3\r\n+b\r\n$6\r\nsecond\r\n+a\r\n$5\r\nfirst\r\n+c\r\n$5\r\nthird\r\n";
    try std.testing.expectEqualStrings(expected, result);
}
