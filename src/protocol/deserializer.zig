const std = @import("std");
const types = @import("types.zig");

pub const Deserializer = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) Deserializer {
        return .{ .arena = .init(allocator) };
    }

    pub fn deinit(self: *Deserializer) void {
        self.arena.deinit();
    }

    pub fn reset(self: *Deserializer) void {
        _ = self.arena.reset(.retain_capacity);
    }

    pub fn process(self: *Deserializer, input: types.ZType) anyerror![]const u8 {
        var output = std.array_list.Managed(u8).init(self.arena.allocator());
        try write(&output, input);
        return output.items;
    }

    pub fn writeArray(output: *std.array_list.Managed(u8), items: []const types.ZType) anyerror!void {
        try output.print("*{d}\r\n", .{items.len});
        for (items) |item| try write(output, item);
    }

    pub fn write(output: *std.array_list.Managed(u8), input: types.ZType) anyerror!void {
        switch (input) {
            .str => |text| {
                try output.print("${d}\r\n", .{text.len});
                try output.appendSlice(text);
                try output.appendSlice("\r\n");
            },
            .sstr => |text| {
                try output.append('+');
                try output.appendSlice(text);
                try output.appendSlice("\r\n");
            },
            .int => |value| try output.print(":{d}\r\n", .{value}),
            .float => |value| try output.print(",{d}\r\n", .{value}),
            .bool => |value| try output.appendSlice(if (value) "#t\r\n" else "#f\r\n"),
            .null => try output.appendSlice("_\r\n"),
            .array => |array| try writeArray(output, array.items),
            .map => |map| {
                try output.print("%{d}\r\n", .{map.count()});
                var iterator = map.iterator();
                while (iterator.next()) |entry| {
                    try write(output, .{ .str = entry.key_ptr.* });
                    try write(output, entry.value_ptr.*);
                }
            },
            .set => |set| {
                try output.print("/{d}\r\n", .{set.count()});
                var iterator = set.iterator();
                while (iterator.next()) |entry| try write(output, entry.key_ptr.*);
            },
            .uset => |set| {
                try output.print("~{d}\r\n", .{set.count()});
                var iterator = set.iterator();
                while (iterator.next()) |entry| try write(output, entry.*);
            },
            else => return error.UnsuportedType,
        }
    }
};
