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

    pub fn process(self: *Deserializer, input: types.ZType) anyerror![]const u8 {
        switch (input) {
            .str => return try self.deserializeString(input),
            .sstr => return try self.deserializeSimpleString(input),
            .int => return try self.deserializeInt(input),
            .bool => return try self.deserializeBool(input),
            .null => return try self.deserializeNull(input),
            .array => return try self.deserialize_array(input),
            .float => return try self.deserialize_float(input),
            .map => return try self.deserializeMap(input),
            .set => return try self.deserializeSet(input),
            .uset => return try self.deserializeUnorderedSet(input),
            else => return error.UnsuportedType,
        }
    }

    fn deserializeString(self: *Deserializer, input: types.ZType) ![]const u8 {
        const bytes = std.fmt.allocPrint(
            self.arena.allocator(),
            "${d}\r\n{s}\r\n",
            .{ input.str.len, input.str },
        ) catch {
            return error.DeserializationError;
        };
        return bytes;
    }

    fn deserializeSimpleString(self: *Deserializer, input: types.ZType) ![]const u8 {
        const bytes = std.fmt.allocPrint(
            self.arena.allocator(),
            "+{s}\r\n",
            .{input.sstr},
        ) catch {
            return error.DeserializationError;
        };
        return bytes;
    }

    fn deserializeInt(self: *Deserializer, input: types.ZType) ![]const u8 {
        const bytes = std.fmt.allocPrint(
            self.arena.allocator(),
            ":{d}\r\n",
            .{input.int},
        ) catch {
            return error.DeserializationError;
        };
        return bytes;
    }

    fn deserializeBool(self: *Deserializer, input: types.ZType) ![]const u8 {
        const bool_byte: *const [1:0]u8 = if (input.bool) "t" else "f";

        const bytes = std.fmt.allocPrint(
            self.arena.allocator(),
            "#{s}\r\n",
            .{bool_byte},
        ) catch {
            return error.DeserializationError;
        };
        return bytes;
    }

    fn deserializeNull(self: *Deserializer, input: types.ZType) ![]const u8 {
        _ = input;
        _ = self;
        return "_\r\n";
    }

    fn deserialize_error(self: *Deserializer, input: types.ZType) ![]const u8 {
        const bytes = std.fmt.allocPrint(
            self.arena.allocator(),
            "-{s}\r\n",
            .{input.err.message},
        ) catch {
            return error.DeserializationError;
        };
        return bytes;
    }

    fn deserialize_float(self: *Deserializer, input: types.ZType) ![]const u8 {
        const bytes = std.fmt.allocPrint(
            self.arena.allocator(),
            ",{d}\r\n",
            .{input.float},
        ) catch {
            return error.DeserializationError;
        };
        return bytes;
    }

    fn deserialize_array(self: *Deserializer, input: types.ZType) ![]const u8 {
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
            const bytes = try self.process(item);
            const res = try std.mem.concat(
                self.arena.allocator(),
                u8,
                &.{ result, bytes },
            );
            result = res;
        }
        return result;
    }

    fn deserializeMap(self: *Deserializer, input: types.ZType) ![]const u8 {
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
            var bytes = try self.process(.{ .str = item.key_ptr.* });
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

    fn deserializeSet(self: *Deserializer, input: types.ZType) ![]const u8 {
        var result: []u8 = undefined;

        const set_prefix = std.fmt.allocPrint(
            self.arena.allocator(),
            "/{d}\r\n",
            .{input.set.count()},
        ) catch {
            return error.DeserializationError;
        };

        result = set_prefix;

        var iterator = input.set.iterator();
        while (iterator.next()) |entry| {
            const bytes = try self.process(entry.key_ptr.*);
            const payload = try std.mem.concat(
                self.arena.allocator(),
                u8,
                &.{ result, bytes },
            );

            result = payload;
        }

        return result;
    }

    fn deserializeUnorderedSet(self: *Deserializer, input: types.ZType) ![]const u8 {
        var result: []u8 = undefined;

        const set_prefix = std.fmt.allocPrint(
            self.arena.allocator(),
            "~{d}\r\n",
            .{input.uset.count()},
        ) catch {
            return error.DeserializationError;
        };

        result = set_prefix;

        var iterator = input.uset.iterator();
        while (iterator.next()) |entry| {
            const bytes = try self.process(entry.*);
            const payload = try std.mem.concat(
                self.arena.allocator(),
                u8,
                &.{ result, bytes },
            );

            result = payload;
        }

        return result;
    }
};
