const std = @import("std");
const activeTag = std.meta.activeTag;

const ZType = @import("ztype.zig").ZType;

const ContextType = enum { ordered, unordered };
pub fn ZContext(comptime ctype: anytype) type {
    switch (ctype) {
        .ordered => return ArrayContext,
        .unordered => return Context,
        else => @compileError("unsupported type"),
    }
}

const Context = struct {
    pub fn hash(ctx: Context, key: ZType) u64 {
        return ztypeHash(ctx, key);
    }

    pub fn eql(ctx: Context, a: ZType, b: ZType) bool {
        _ = ctx;
        return ztypeEql(a, b);
    }
};

const ArrayContext = struct {
    pub fn hash(ctx: ArrayContext, key: ZType) u32 {
        return @truncate(ztypeHash(ctx, key));
    }

    pub fn eql(ctx: ArrayContext, a: ZType, b: ZType, _: usize) bool {
        _ = ctx;
        return ztypeEql(a, b);
    }
};

fn ztypeHash(ctx: anytype, key: ZType) u64 {
    var hasher = std.hash.Wyhash.init(0);

    switch (key) {
        .str, .sstr => |v| hasher.update(v),
        inline .int, .float, .bool, .null => |v| {
            hasher.update(std.mem.asBytes(&v));
        },
        .array => |v| {
            for (v.items) |item| {
                const hashed = ctx.hash(item);
                hasher.update(std.mem.asBytes(&hashed));
            }
        },
        .map => |v| {
            var iter = v.iterator();
            while (iter.next()) |item| {
                var hashed_key: u64 = ctx.hash(.{ .str = @constCast(item.key_ptr.*) });
                var hashed_value: u64 = ctx.hash(item.value_ptr.*);

                hasher.update(std.mem.asBytes(&hashed_key));
                hasher.update(std.mem.asBytes(&hashed_value));
            }
        },
        inline .uset, .set => |v, tag| {
            var iter = v.iterator();
            while (iter.next()) |item| {
                const hashed = switch (tag) {
                    .set => ctx.hash(item.key_ptr.*),
                    .uset => ctx.hash(item.*),
                    else => @compileError("unsupported type"),
                };
                hasher.update(std.mem.asBytes(&hashed));
            }
        },
        else => unreachable,
    }
    return hasher.final();
}

fn ztypeEql(a: ZType, b: ZType) bool {
    if (activeTag(a) != activeTag(b)) return false;

    switch (a) {
        inline .str, .sstr => |v, tag| return std.mem.eql(
            u8,
            v,
            @field(b, @tagName(tag)),
        ),
        inline .int, .float, .bool => |v, tag| return v == @field(
            b,
            @tagName(tag),
        ),
        .null => return true,
        .array => |v| {
            if (v.items.len != b.array.items.len) return false;

            var equal_items: usize = 0;

            for (v.items) |item| {
                for (b.array.items) |b_item| {
                    if (activeTag(item) == activeTag(b_item)) {
                        if (!ztypeEql(item, b_item)) continue;
                        equal_items += 1;
                    }
                }
            }

            if (equal_items != v.items.len) return false;

            return true;
        },
        .map => |v| {
            var both_equals = false;

            var iter = v.iterator();
            while (iter.next()) |v_entry| {
                var b_iter = b.map.iterator();

                while (b_iter.next()) |b_entry| {
                    const v_tag = activeTag(v_entry.value_ptr.*);
                    const b_tag = activeTag(b_entry.value_ptr.*);

                    if (v_tag != b_tag) continue; // order could be incorrect.

                    // map keys are always strings.
                    const keys_equals = ztypeEql(
                        ZType{ .str = @constCast(v_entry.key_ptr.*) },
                        ZType{ .str = @constCast(b_entry.key_ptr.*) },
                    );
                    const values_equals = ztypeEql(
                        v_entry.value_ptr.*,
                        b_entry.value_ptr.*,
                    );

                    if (keys_equals and values_equals) {
                        both_equals = true;
                        break;
                    }
                }
                if (both_equals) break;
            }
            return both_equals;
        },
        inline .uset, .set => |v, tag| {
            var equal_items: usize = 0;

            var iter = v.iterator();
            while (iter.next()) |item| {
                var b_iter = @field(b, @tagName(tag)).iterator();
                while (b_iter.next()) |b_item| {
                    const deref_items: [2]ZType = switch (tag) {
                        .set => .{ item.key_ptr.*, b_item.key_ptr.* },
                        .uset => .{ item.*, b_item.* },
                        else => @compileError("unsupported type"),
                    };

                    if (activeTag(deref_items[0]) == activeTag(deref_items[1])) {
                        if (!ztypeEql(deref_items[0], deref_items[1])) continue;
                        equal_items += 1;
                    }
                }
            }

            if (equal_items != v.count()) return false;

            return true;
        },
        else => unreachable,
    }

    return false;
}
