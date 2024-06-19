const std = @import("std");
pub const sets = @import("set.zig");

pub const ZType = union(enum) {
    str: []u8,
    sstr: []u8, // simple string
    int: i64,
    float: f64,
    map: map,
    bool: bool,
    array: array,
    set: set,
    uset: uset,
    null: void,
    // ClientError only for compatibility with ProtocolHandler
    // and it will not be stored in Memory but will be returned
    err: ClientError,

    pub const array = std.ArrayList(ZType);
    pub const map = std.StringHashMap(ZType);

    pub const set = sets.Set(ZType);
    pub const uset = sets.SetUnordered(ZType);
};

pub const ClientError = struct {
    message: []const u8,
};

pub fn ztype_copy(value: ZType, allocator: std.mem.Allocator) anyerror!ZType {
    switch (value) {
        .str => return .{ .str = try allocator.dupe(u8, value.str) },
        .sstr => return .{ .sstr = try allocator.dupe(u8, value.sstr) },
        // we do not need to copy int, floats, bools and nulls
        // because we already have it content unless strings and others
        .int, .float, .bool, .null => return value,
        .array => |array| {
            var result = std.ArrayList(ZType).init(allocator);

            for (array.items) |item| {
                const copied = try ztype_copy(item, allocator);
                try result.append(copied);
            }

            return .{ .array = result };
        },
        .map => |v| {
            var result = std.StringHashMap(ZType).init(allocator);

            var iter = v.iterator();
            while (iter.next()) |entry| {
                const zkey = try ztype_copy(
                    .{ .str = @constCast(entry.key_ptr.*) },
                    allocator,
                );
                const zvalue = try ztype_copy(entry.value_ptr.*, allocator);

                try result.put(zkey.str, zvalue);
            }

            return .{ .map = result };
        },
        .set => {
            var result = ZType.set.init(allocator);

            var iter = value.set.iterator();
            while (iter.next()) |item| {
                const copied = try ztype_copy(
                    item.key_ptr.*,
                    allocator,
                );
                try result.insert(copied);
            }

            return .{ .set = result };
        },
        .uset => {
            var result = ZType.uset.init(allocator);

            var iter = value.uset.iterator();
            while (iter.next()) |item| {
                const copied = try ztype_copy(
                    item.*,
                    allocator,
                );
                try result.insert(copied);
            }

            return .{ .uset = result };
        },
        // we do not implement for err because errors wont be stored in Memory
        else => return error.UnsuportedType,
    }
}

pub fn ztype_free(value: *ZType, allocator: std.mem.Allocator) void {
    switch (value.*) {
        .str, .sstr => |str| allocator.free(str),
        .int, .float, .bool, .null => return,
        .array => |array| {
            defer array.deinit();

            for (array.items) |item| ztype_free(
                @constCast(&item),
                allocator,
            );
        },
        .map => |v| {
            defer @constCast(&v).deinit();

            var iter = v.iterator();
            while (iter.next()) |item| {
                var zkey: ZType = .{ .str = @constCast(item.key_ptr.*) };
                var zvalue: ZType = item.value_ptr.*;

                ztype_free(&zkey, allocator);
                ztype_free(&zvalue, allocator);
            }
        },
        .set => |v| {
            defer @constCast(&v).deinit();

            var iter = v.iterator();
            while (iter.next()) |item| ztype_free(
                item.key_ptr,
                allocator,
            );
        },
        .uset => |v| {
            defer @constCast(&v).deinit();

            var iter = v.iterator();
            while (iter.next()) |item| ztype_free(
                item, // already a pointer.
                allocator,
            );
        },
        else => unreachable,
    }
}
