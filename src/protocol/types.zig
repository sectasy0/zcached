//! Protocol value types and helpers for copying and releasing nested values.

const std = @import("std");
/// Set implementations available to protocol data structures.
pub const sets = @import("set.zig");

/// Tagged values supported by the protocol parser and encoder.
pub const ZType = union(enum) {
    /// Bulk string bytes, borrowed or owned according to the containing value's lifetime.
    str: []const u8,
    // sstring (simple string) is rather response format than data
    /// Simple-string bytes, used for protocol responses.
    sstr: []const u8,
    /// Signed integer value.
    int: i64,
    /// Floating-point value.
    float: f64,
    /// String-keyed collection of recursively typed values.
    map: Map,
    /// Boolean value.
    bool: bool,
    /// Ordered sequence of recursively typed values.
    array: Array,
    /// Insertion-ordered collection of unique values.
    set: Set,
    /// Collection of unique values with unspecified iteration order.
    uset: USet,
    /// Protocol null value, represented without payload.
    null: void,
    // ClientError only for compatibility with ProtocolHandler
    // and it will not be stored in Memory but will be returned
    /// Client error payload retained for handler compatibility, not storage.
    err: ClientError,

    /// Managed list type used by the array variant.
    pub const Array = std.array_list.Managed(ZType);
    /// String-keyed map type used by the map variant.
    pub const Map = std.StringHashMap(ZType);

    /// Ordered set type used by the set variant.
    pub const Set = sets.Set(ZType);
    /// Unordered set type used by the uset variant.
    pub const USet = sets.SetUnordered(ZType);
};

/// Error response data returned to protocol clients.
pub const ClientError = struct {
    /// Message bytes whose storage remains owned by the caller.
    message: []const u8,
};

/// Recursively duplicates dynamically stored data into `allocator`.
/// Scalar values are copied directly; unsupported error values return an error.
pub fn ztype_copy(value: ZType, allocator: std.mem.Allocator) anyerror!ZType {
    switch (value) {
        .str => return .{ .str = try allocator.dupe(u8, value.str) },
        .sstr => return .{ .sstr = try allocator.dupe(u8, value.sstr) },
        // we do not need to copy int, floats, bools and nulls
        // because we already have it content unless strings and others
        .int, .float, .bool, .null => return value,
        .array => |array| {
            var result = try std.array_list.Managed(ZType).initCapacity(allocator, array.items.len);
            errdefer {
                var partial: ZType = .{ .array = result };
                ztype_free(&partial, allocator);
            }

            for (array.items) |item| {
                const copied = try ztype_copy(item, allocator);
                result.appendAssumeCapacity(copied);
            }

            return .{ .array = result };
        },
        .map => |v| {
            var result = std.StringHashMap(ZType).init(allocator);
            errdefer {
                var partial: ZType = .{ .map = result };
                ztype_free(&partial, allocator);
            }

            var iter = v.iterator();
            while (iter.next()) |entry| {
                const zkey = try ztype_copy(
                    .{ .str = entry.key_ptr.* },
                    allocator,
                );
                errdefer allocator.free(zkey.str);
                var zvalue = try ztype_copy(entry.value_ptr.*, allocator);
                errdefer ztype_free(&zvalue, allocator);

                try result.put(zkey.str, zvalue);
            }

            return .{ .map = result };
        },
        .set => {
            var result = ZType.Set.init(allocator);
            errdefer {
                var partial: ZType = .{ .set = result };
                ztype_free(&partial, allocator);
            }

            var iter = value.set.iterator();
            while (iter.next()) |item| {
                var copied = try ztype_copy(
                    item.key_ptr.*,
                    allocator,
                );
                errdefer ztype_free(&copied, allocator);
                try result.insert(copied);
            }

            return .{ .set = result };
        },
        .uset => {
            var result = ZType.USet.init(allocator);
            errdefer {
                var partial: ZType = .{ .uset = result };
                ztype_free(&partial, allocator);
            }

            var iter = value.uset.iterator();
            while (iter.next()) |item| {
                var copied = try ztype_copy(
                    item.*,
                    allocator,
                );
                errdefer ztype_free(&copied, allocator);
                try result.insert(copied);
            }

            return .{ .uset = result };
        },
        // we do not implement for err because errors wont be stored in Memory
        else => return error.UnsuportedType,
    }
}

/// Frees dynamically owned strings and nested containers in supported variants.
/// The allocator must match the one used to create those allocations.
pub fn ztype_free(value: *ZType, allocator: std.mem.Allocator) void {
    switch (value.*) {
        .str, .sstr => |str| allocator.free(str),
        .int, .float, .bool, .null => return,
        .array => |array| {
            defer array.deinit();

            for (value.array.items) |item| ztype_free(
                @constCast(&item),
                allocator,
            );
        },
        .map => |v| {
            defer value.*.map.deinit();

            var iter = v.iterator();
            while (iter.next()) |item| {
                var zkey: ZType = .{ .str = item.key_ptr.* };
                var zvalue: ZType = item.value_ptr.*;

                ztype_free(&zkey, allocator);
                ztype_free(&zvalue, allocator);
            }
        },
        inline .set, .uset => |v, tag| {
            defer @constCast(&v).deinit();

            var iter = v.iterator();
            while (iter.next()) |item| {
                const value_ptr = switch (tag) {
                    .set => item.key_ptr,
                    .uset => item,
                    else => @compileError("not supported tag"),
                };
                ztype_free(
                    value_ptr,
                    allocator,
                );
            }
        },
        else => unreachable,
    }
}
