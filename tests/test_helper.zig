const std = @import("std");

const Config = @import("../src/server/config.zig");
const MemoryStorage = @import("../src/server/storage.zig");
const TracingAllocator = @import("../src/server/tracing.zig").TracingAllocator;
const PersistanceHandler = @import("../src/server/persistance.zig").PersistanceHandler;
const CMDHandler = @import("../src/server/cmd_handler.zig").CMDHandler;
const types = @import("../src/protocol/types.zig");
const log = @import("../src/server/logger.zig");
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

            for (first.array.items, second.array.items) |fitem, sitem| {
                try expectEqualZTypes(fitem, sitem);
            }
        },
        .map => {
            if (first.map.count() != second.map.count()) return error.NotEqual;

            var fiter = first.map.iterator();

            var equal_items: i64 = 0;

            for (0..first.map.count()) |_| {
                var fitem = fiter.next();
                var siter = second.map.iterator();
                if (fitem == null) continue;

                for (0..second.map.count()) |_| {
                    var sitem = siter.next();

                    if (sitem == null) continue;
                    if (activeTag(fitem.?.value_ptr.*) == activeTag(sitem.?.value_ptr.*)) {
                        try expectEqualZTypes(
                            fitem.?.value_ptr.*,
                            sitem.?.value_ptr.*,
                        );
                        equal_items += 1;
                    }
                }
            }

            if (equal_items != first.map.count()) return error.NotEqual;
        },
        .str => try std.testing.expectEqualStrings(first.str, second.str),
        .sstr => try std.testing.expectEqualStrings(first.sstr, second.sstr),
        .int => try std.testing.expectEqual(first, second),
        .float => try std.testing.expectEqual(first, second),
        .bool => try std.testing.expectEqual(first, second),
        .null => try std.testing.expectEqual(first, second),
        else => unreachable,
    }
}
