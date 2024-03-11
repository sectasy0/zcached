const std = @import("std");

pub const ZType = union(enum) {
    str: []u8,
    sstr: []u8, // simple string
    int: i64,
    float: f64,
    map: map,
    bool: bool,
    array: array,
    null: void,
    // ClientError only for compatibility with ProtocolHandler
    // and it will not be stored in MemoryStorage but will be returned
    err: ClientError,

    pub const array = std.ArrayList(ZType);
    pub const map = std.StringHashMap(ZType);
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
                var copied = try ztype_copy(item, allocator);
                try result.append(copied);
            }

            return .{ .array = result };
        },
        .map => {
            var result = std.StringHashMap(ZType).init(allocator);

            var iter = value.map.iterator();
            while (iter.next()) |item| {
                const zkey = try ztype_copy(.{ .str = @constCast(item.key_ptr.*) }, allocator);
                const zvalue = try ztype_copy(item.value_ptr.*, allocator);

                try result.put(zkey.str, zvalue);
            }

            return .{ .map = result };
        },
        // we do not implement for err because errors wont be stored in MemoryStorage
        else => return error.UnsuportedType,
    }

    return value;
}

pub fn ztype_free(value: *ZType, allocator: std.mem.Allocator) void {
    switch (value.*) {
        .str, .sstr => |str| allocator.free(str),
        .int, .float, .bool, .null => return,
        .array => |array| {
            defer array.deinit();

            for (array.items) |item| ztype_free(@constCast(&item), allocator);
        },
        .map => |map| {
            defer value.map.deinit();

            var iter = map.iterator();

            while (iter.next()) |item| {
                var zkey: ZType = .{ .str = @constCast(item.key_ptr.*) };
                var zvalue: ZType = item.value_ptr.*;

                ztype_free(&zkey, allocator);
                ztype_free(&zvalue, allocator);
            }
        },
        else => return,
    }
}
