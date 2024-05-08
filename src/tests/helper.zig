const std = @import("std");

const Config = @import("../server/config.zig");
const MemoryStorage = @import("../server/storage.zig");
const PersistanceHandler = @import("../server/persistance.zig").PersistanceHandler;
const CMDHandler = @import("../server/cmd_handler.zig").CMDHandler;
const types = @import("../protocol/types.zig");
const Logger = @import("../server/logger.zig");
const activeTag = std.meta.activeTag;

pub const STRING: []u8 = @constCast("Was wir wissen, ist ein Tropfen, was wir nicht wissen, ein Ozean.");
pub const SIMPLE_STRING: []u8 = @constCast("simple string");

pub fn setup_array(allocator: std.mem.Allocator) !std.ArrayList(types.ZType) {
    var array = std.ArrayList(types.ZType).init(allocator);
    try array.append(.{ .str = STRING });
    try array.append(.{ .sstr = SIMPLE_STRING });
    try array.append(.{ .int = 47 });
    try array.append(.{ .float = 47.47 });
    try array.append(.{ .bool = false });
    try array.append(.{ .null = void{} });
    return array;
}

pub fn setup_map(allocator: std.mem.Allocator) !std.StringHashMap(types.ZType) {
    var map = std.StringHashMap(types.ZType).init(allocator);
    try map.put("test5", .{ .str = STRING });
    try map.put("test6", .{ .sstr = SIMPLE_STRING });
    try map.put("test1", .{ .int = 88 });
    try map.put("test2", .{ .float = 88.45 });
    try map.put("test3", .{ .bool = true });
    try map.put("test4", .{ .null = void{} });
    return map;
}

pub fn setup_storage(storage: *MemoryStorage) !void {
    try storage.put("foo", .{ .int = 42 });
    try storage.put("foo2", .{ .float = 123.45 });
    try storage.put("foo3", .{ .bool = true });
    try storage.put("foo4", .{ .null = void{} });
    try storage.put("foo5", .{ .sstr = SIMPLE_STRING });
    try storage.put("bar", .{ .str = STRING });
}

pub fn expectEqualZTypes(first: types.ZType, second: types.ZType) !void {
    if (@TypeOf(first) != @TypeOf(second)) return error.NotEqual;

    switch (first) {
        .array => {
            if (first.array.items.len != second.array.items.len) return error.NotEqual;

            var equal_items: i64 = 0;

            for (first.array.items) |fitem| {
                for (second.array.items) |sitem| {
                    if (activeTag(fitem) == activeTag(sitem)) {
                        expectEqualZTypes(fitem, sitem) catch continue;
                        equal_items += 1;
                    }
                }
            }

            if (equal_items != first.array.items.len) return error.NotEqual;
        },
        .map => {
            if (first.map.count() != second.map.count()) return error.NotEqual;

            var fiter = first.map.iterator();

            var equal_items: i64 = 0;

            for (0..first.map.count()) |_| {
                const fitem = fiter.next();
                var siter = second.map.iterator();
                if (fitem == null) continue;

                for (0..second.map.count()) |_| {
                    const sitem = siter.next();

                    if (sitem == null) continue;
                    if (activeTag(fitem.?.value_ptr.*) == activeTag(sitem.?.value_ptr.*)) {
                        expectEqualZTypes(
                            fitem.?.value_ptr.*,
                            sitem.?.value_ptr.*,
                        ) catch continue;
                        equal_items += 1;
                    }
                }
            }

            if (equal_items != first.map.count()) return error.NotEqual;
        },
        .str => {
            if (std.mem.eql(u8, first.str, second.str)) {
                return;
            } else {
                return error.NotEqual;
            }
        },
        .sstr => try std.testing.expectEqualStrings(first.sstr, second.sstr),
        .int => try std.testing.expectEqual(first, second),
        .float => try std.testing.expectEqual(first, second),
        .bool => try std.testing.expectEqual(first, second),
        .null => try std.testing.expectEqual(first, second),
        else => unreachable,
    }
}
