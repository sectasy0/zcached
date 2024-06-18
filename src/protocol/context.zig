const std = @import("std");
const activeTag = std.meta.activeTag;

const ZType = @import("types.zig").ZType;

pub const ZTypeContext = struct {
    pub fn hash(ctx: ZTypeContext, key: ZType) u64 {
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
            .uset => |v| {
                var iter = v.iterator();
                while (iter.next()) |item| {
                    const hashed = ctx.hash(item.*);
                    hasher.update(std.mem.asBytes(&hashed));
                }
            },
            .set => |v| {
                var iter = v.iterator();
                while (iter.next()) |item| {
                    const hashed = ctx.hash(item.key_ptr.*);
                    hasher.update(std.mem.asBytes(&hashed));
                }
            },
            else => unreachable,
        }
        return hasher.final();
    }

    pub fn eql(ctx: ZTypeContext, a: ZType, b: ZType) bool {
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

                for (v.items, 0..) |item, i| return ctx.eql(
                    item,
                    b.array.items[i],
                );
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
                        const keys_equals = ctx.eql(
                            ZType{ .str = @constCast(v_entry.key_ptr.*) },
                            ZType{ .str = @constCast(b_entry.key_ptr.*) },
                        );
                        const values_equals = ctx.eql(
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
            .uset => |v| {
                var all_equals = false;

                var iter = v.iterator();
                while (iter.next()) |item| {
                    var b_iter = b.uset.iterator();

                    var item_equals = false;
                    while (b_iter.next()) |b_item| {
                        if (activeTag(item.*) != activeTag(b_item.*)) continue; // order could be incorrect.

                        if (ctx.eql(item.*, b_item.*)) {
                            item_equals = true;
                            break;
                        }
                    }

                    if (!item_equals) {
                        all_equals = false;
                        break;
                    }
                }
            },
            .set => |v| {
                var all_equals = false;

                var iter = v.iterator();
                while (iter.next()) |item| {
                    var b_iter = b.set.iterator();

                    var item_equals = false;
                    while (b_iter.next()) |b_item| {
                        if (activeTag(item.key_ptr.*) != activeTag(b_item.key_ptr.*)) continue; // order could be incorrect.

                        if (ctx.eql(item.key_ptr.*, b_item.key_ptr.*)) {
                            item_equals = true;
                            break;
                        }
                    }

                    if (!item_equals) {
                        all_equals = false;
                        break;
                    }
                }
            },
            else => unreachable,
        }
        return false;
    }
};

pub const ZTypeArrayContext = struct {
    pub fn hash(ctx: ZTypeArrayContext, key: ZType) u32 {
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
            .uset => |v| {
                var iter = v.iterator();
                while (iter.next()) |item| {
                    const hashed = ctx.hash(item.*);
                    hasher.update(std.mem.asBytes(&hashed));
                }
            },
            .set => |v| {
                var iter = v.iterator();
                while (iter.next()) |item| {
                    const hashed = ctx.hash(item.key_ptr.*);
                    hasher.update(std.mem.asBytes(&hashed));
                }
            },
            else => unreachable,
        }
        return @truncate(hasher.final());
    }

    pub fn eql(ctx: ZTypeArrayContext, a: ZType, b: ZType, b_index: usize) bool {
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

                for (v.items, 0..) |item, i| return ctx.eql(
                    item,
                    b.array.items[i],
                    i,
                );
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
                        const keys_equals = ctx.eql(
                            ZType{ .str = @constCast(v_entry.key_ptr.*) },
                            ZType{ .str = @constCast(b_entry.key_ptr.*) },
                            b_index,
                        );
                        const values_equals = ctx.eql(
                            v_entry.value_ptr.*,
                            b_entry.value_ptr.*,
                            b_index,
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
            .uset => |v| {
                var all_equals = false;

                var iter = v.iterator();
                while (iter.next()) |item| {
                    var b_iter = b.uset.iterator();

                    var item_equals = false;
                    while (b_iter.next()) |b_item| {
                        if (activeTag(item.*) != activeTag(b_item.*)) continue; // order could be incorrect.

                        if (ctx.eql(item.*, b_item.*, b_index)) {
                            item_equals = true;
                            break;
                        }
                    }

                    if (!item_equals) {
                        all_equals = false;
                        break;
                    }
                }
            },
            .set => |v| {
                var all_equals = false;

                var iter = v.iterator();
                while (iter.next()) |item| {
                    var b_iter = b.set.iterator();

                    var item_equals = false;
                    while (b_iter.next()) |b_item| {
                        if (activeTag(item.key_ptr.*) != activeTag(b_item.key_ptr.*)) continue; // order could be incorrect.

                        if (ctx.eql(item.key_ptr.*, b_item.key_ptr.*, b_index)) {
                            item_equals = true;
                            break;
                        }
                    }

                    if (!item_equals) {
                        all_equals = false;
                        break;
                    }
                }
            },
            else => unreachable,
        }

        return false;
    }
};
