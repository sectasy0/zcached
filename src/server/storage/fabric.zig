//! Routes operations to shards and coordinates cross-shard operations.
const std = @import("std");
const sync = @import("sync");
const types = @import("../../protocol/types.zig");
const Config = @import("../config.zig");
pub const Shard = @import("shard.zig");
const Fabric = @This();

shards: []Shard,
allocator: std.mem.Allocator,
limit: usize,
limit_lock: sync.Mutex = .{},

pub fn init(allocator: std.mem.Allocator, config: Config.Memory) !Fabric {
    if (config.shard_count == 0) return error.InvalidShardCount;
    // HashMap rounds the load-adjusted capacity up to a power of two in u32.
    const max_capacity = ((@as(u64, 1) << 31) - 1) * std.hash_map.default_max_load_percentage / 100;
    if (config.default_capacity > max_capacity) return error.InvalidCapacity;
    const capacity = std.math.cast(u32, config.default_capacity) orelse return error.InvalidCapacity;
    const shards = try allocator.alloc(Shard, config.shard_count);
    errdefer allocator.free(shards);
    var initialized: usize = 0;
    errdefer for (shards[0..initialized]) |*shard| shard.deinit();
    for (shards) |*shard| {
        try shard.init(allocator, capacity);
        initialized += 1;
    }
    return .{
        .shards = shards,
        .allocator = allocator,
        .limit = config.limit,
    };
}

pub fn shardIndex(self: *const Fabric, key: []const u8) usize {
    return @intCast(std.hash.Wyhash.hash(0, key) % self.shards.len);
}

fn shardFor(self: *Fabric, key: []const u8) *Shard {
    return &self.shards[self.shardIndex(key)];
}

/// Reports live requested bytes, including map capacities but excluding heap metadata.
pub fn memoryUsed(self: *Fabric) usize {
    var total: usize = 0;
    for (self.shards) |*shard| {
        shard.lock.lockShared();
        total += shard.heap.total_requested_bytes;
        shard.lock.unlockShared();
    }
    return total;
}

fn checkLimit(self: *Fabric) !void {
    if (self.limit != 0 and self.memoryUsed() >= self.limit)
        return error.MemoryLimitExceeded;
}

pub fn put(self: *Fabric, key: []const u8, value: types.ZType) !void {
    if (self.limit != 0) self.limit_lock.lock();
    defer if (self.limit != 0) self.limit_lock.unlock();
    try self.checkLimit();
    const shard = self.shardFor(key);
    shard.lock.lock();
    defer shard.lock.unlock();
    try shard.put(key, .{ .value = value });
}

pub fn get(self: *Fabric, key: []const u8) !types.ZType {
    const shard = self.shardFor(key);
    shard.lock.lockShared();
    defer shard.lock.unlockShared();
    return (shard.map.get(key) orelse return error.NotFound).value;
}

pub fn getCopy(self: *Fabric, key: []const u8, allocator: std.mem.Allocator) !types.ZType {
    const shard = self.shardFor(key);
    shard.lock.lockShared();
    defer shard.lock.unlockShared();
    return types.ztype_copy((shard.map.get(key) orelse return error.NotFound).value, allocator);
}

pub fn withValue(self: *Fabric, key: []const u8, context: anytype, callback: anytype) !void {
    const shard = self.shardFor(key);
    shard.lock.lockShared();
    defer shard.lock.unlockShared();
    try callback(context, (shard.map.get(key) orelse return error.NotFound).value);
}

pub fn valueSize(self: *Fabric, key: []const u8) !usize {
    const shard = self.shardFor(key);
    shard.lock.lockShared();
    defer shard.lock.unlockShared();
    return switch ((shard.map.get(key) orelse return error.NotFound).value) {
        .str, .sstr => |text| text.len,
        .array => |array| array.items.len,
        inline .map, .set, .uset => |collection| collection.count(),
        inline .int, .float, .bool => |scalar| @sizeOf(@TypeOf(scalar)),
        else => 0,
    };
}

pub fn delete(self: *Fabric, key: []const u8) bool {
    const shard = self.shardFor(key);
    shard.lock.lock();
    defer shard.lock.unlock();
    return shard.delete(key);
}

pub fn flush(self: *Fabric) void {
    for (self.shards) |*shard| shard.lock.lock();
    defer {
        var index = self.shards.len;
        while (index > 0) {
            index -= 1;
            self.shards[index].lock.unlock();
        }
    }
    for (self.shards) |*shard| shard.flush();
}

pub fn size(self: *Fabric) usize {
    var iter = self.iterator();
    defer iter.deinit();
    return iter.count();
}

pub fn keys(self: *Fabric, allocator: std.mem.Allocator) !types.ZType.Array {
    var iter = self.iterator();
    defer iter.deinit();
    var result = try types.ZType.Array.initCapacity(allocator, iter.count());
    errdefer result.deinit();
    while (iter.next()) |entry| result.appendAssumeCapacity(.{ .str = entry.key_ptr.* });
    return result;
}

pub fn keysCopy(self: *Fabric, allocator: std.mem.Allocator) !types.ZType.Array {
    var iter = self.iterator();
    defer iter.deinit();
    var result = try types.ZType.Array.initCapacity(allocator, iter.count());
    errdefer {
        for (result.items) |*key| types.ztype_free(key, allocator);
        result.deinit();
    }
    while (iter.next()) |entry|
        result.appendAssumeCapacity(.{ .str = try allocator.dupe(u8, entry.key_ptr.*) });
    return result;
}

pub fn rename(self: *Fabric, source: []const u8, destination: []const u8) !void {
    return self.transfer(source, destination, true, true);
}

pub fn copy(self: *Fabric, source: []const u8, destination: []const u8, replace: bool) !void {
    return self.transfer(source, destination, replace, false);
}

fn transfer(self: *Fabric, source: []const u8, destination: []const u8, replace: bool, move: bool) !void {
    if (self.limit != 0) self.limit_lock.lock();
    defer if (self.limit != 0) self.limit_lock.unlock();
    if (!move or destination.len > source.len) try self.checkLimit();

    const source_index = self.shardIndex(source);
    const destination_index = self.shardIndex(destination);
    const first = &self.shards[@min(source_index, destination_index)];
    const second = &self.shards[@max(source_index, destination_index)];
    first.lock.lock();
    defer first.lock.unlock();
    if (first != second) second.lock.lock();
    defer if (first != second) second.lock.unlock();

    const source_shard = &self.shards[source_index];
    const destination_shard = &self.shards[destination_index];
    const entry = source_shard.map.get(source) orelse return error.NotFound;
    if (!replace and destination_shard.map.contains(destination)) return error.BusyKey;
    if (std.mem.eql(u8, source, destination)) return;

    // Copy with the destination allocator before removing anything from the source.
    try destination_shard.put(destination, entry);
    if (move) {
        const deleted = source_shard.delete(source);
        std.debug.assert(deleted);
    }
}

pub const Iterator = struct {
    fabric: *Fabric,
    shard_index: usize = 0,
    current: ?Shard.Map.Iterator = null,

    pub const Entry = struct {
        key_ptr: *[]const u8,
        value_ptr: *types.ZType,
    };

    pub fn next(self: *Iterator) ?Entry {
        while (self.shard_index < self.fabric.shards.len) {
            if (self.current == null)
                self.current = self.fabric.shards[self.shard_index].map.iterator();
            if (self.current.?.next()) |entry|
                return .{ .key_ptr = entry.key_ptr, .value_ptr = &entry.value_ptr.value };
            self.shard_index += 1;
            self.current = null;
        }
        return null;
    }

    pub fn count(self: *const Iterator) usize {
        var total: usize = 0;
        for (self.fabric.shards) |*shard| total += shard.map.count();
        return total;
    }

    pub fn deinit(self: *Iterator) void {
        var index = self.fabric.shards.len;
        while (index > 0) {
            index -= 1;
            self.fabric.shards[index].lock.unlockShared();
        }
        self.* = undefined;
    }
};

/// The caller must deinitialize the iterator even if iteration stops early.
pub fn iterator(self: *Fabric) Iterator {
    for (self.shards) |*shard| shard.lock.lockShared();
    return .{ .fabric = self };
}

pub fn deinit(self: *Fabric) void {
    for (self.shards) |*shard| shard.deinit();
    self.allocator.free(self.shards);
}
