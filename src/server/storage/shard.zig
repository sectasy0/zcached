//! A shard owns its map, lock, and independently managed heap.
const std = @import("std");
const sync = @import("sync");
const types = @import("../../protocol/types.zig");

const Shard = @This();
const Heap = std.heap.DebugAllocator(.{
    .thread_safe = false,
    .enable_memory_limit = true,
});

pub const Entry = struct {
    expired_at: i64 = 0, // Unix milliseconds; zero means persistent.
    value: types.ZType,

    pub fn isExpired(self: Entry, now: i64) bool {
        return self.expired_at != 0 and self.expired_at <= now;
    }
};

pub const Map = std.StringHashMap(Entry);

map: Map,
lock: sync.RwLock = .{},
heap: Heap,
expiring: usize = 0,

/// Initialize in place: the map's allocator points into this shard.
pub fn init(self: *Shard, backing_allocator: std.mem.Allocator, capacity: u32) !void {
    self.* = .{
        .map = undefined,
        .heap = .{ .backing_allocator = backing_allocator },
    };
    self.map = Map.init(self.heap.allocator());
    errdefer {
        self.map.deinit();
        _ = self.heap.deinit();
    }
    try self.map.ensureTotalCapacity(capacity);
}

/// Caller holds this shard's exclusive lock.
pub fn put(self: *Shard, key: []const u8, entry: Entry) !void {
    if (entry.value == .err) return error.InvalidValue;
    if (self.map.getPtr(key)) |stored| {
        const old: ?[]const u8 = switch (stored.value) {
            .str, .sstr => |bytes| bytes,
            else => null,
        };
        const incoming: ?[]const u8 = switch (entry.value) {
            .str, .sstr => |bytes| bytes,
            else => null,
        };
        if (old != null and incoming != null and
            std.meta.activeTag(stored.value) == std.meta.activeTag(entry.value) and
            old.?.len == incoming.?.len)
        {
            @memmove(@constCast(old.?), incoming.?);
            self.setExpiry(stored, entry.expired_at);
            return;
        }
        const value = try types.ztype_copy(entry.value, self.heap.allocator());
        types.ztype_free(&stored.value, self.heap.allocator());
        stored.value = value;
        self.setExpiry(stored, entry.expired_at);
        return;
    }

    const allocator = self.heap.allocator();
    var value = try types.ztype_copy(entry.value, allocator);
    errdefer types.ztype_free(&value, allocator);
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);

    try self.map.put(owned_key, .{ .value = value, .expired_at = entry.expired_at });
    if (entry.expired_at != 0) self.expiring += 1;
}

pub fn setExpiry(self: *Shard, entry: *Entry, deadline: i64) void {
    if (entry.expired_at != 0) self.expiring -= 1;
    entry.expired_at = deadline;
    if (deadline != 0) self.expiring += 1;
}

/// Caller holds this shard's exclusive lock.
pub fn delete(self: *Shard, key: []const u8) bool {
    var entry = self.map.fetchRemove(key) orelse return false;
    if (entry.value.expired_at != 0) self.expiring -= 1;
    self.heap.allocator().free(entry.key);
    types.ztype_free(&entry.value.value, self.heap.allocator());
    return true;
}

pub fn purgeExpired(self: *Shard, now: i64) void {
    var iter = self.map.iterator();
    while (self.expiring != 0) {
        const entry = iter.next() orelse break;
        if (!entry.value_ptr.isExpired(now)) continue;
        self.heap.allocator().free(entry.key_ptr.*);
        types.ztype_free(&entry.value_ptr.value, self.heap.allocator());
        self.map.removeByPtr(entry.key_ptr);
        self.expiring -= 1;
    }
}

/// Caller holds this shard's exclusive lock.
pub fn flush(self: *Shard) void {
    const allocator = self.heap.allocator();
    var iter = self.map.iterator();
    while (iter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        types.ztype_free(&entry.value_ptr.value, allocator);
    }
    self.map.clearRetainingCapacity();
    self.expiring = 0;
}

pub fn deinit(self: *Shard) void {
    self.flush();
    self.map.deinit();
    const status = self.heap.deinit();
    std.debug.assert(status == .ok);
}
