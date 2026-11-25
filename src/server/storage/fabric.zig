//! Routes operations to shards and coordinates cross-shard operations.
const std = @import("std");
const runtime_io = @import("runtime_io");
const types = @import("../../protocol/types.zig");
const Config = @import("../config.zig");
pub const Shard = @import("shard.zig");
const Fabric = @This();

shards: []Shard,
allocator: std.mem.Allocator,
limit: usize,
used_bytes: std.atomic.Value(usize),
// Startup replay reconstructs historical mutations before applying today's deadlines.
replaying: bool = false,

pub fn unixMillis() i64 {
    return std.Io.Clock.real.now(runtime_io.get()).toMilliseconds();
}

fn expiryTime(self: *const Fabric) i64 {
    return if (self.replaying) 0 else unixMillis();
}

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
    var used_bytes: usize = 0;
    for (shards) |*shard| used_bytes += shard.heap.total_requested_bytes;
    return .{
        .shards = shards,
        .allocator = allocator,
        .limit = config.limit,
        .used_bytes = .init(used_bytes),
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
    return self.used_bytes.load(.monotonic);
}

fn updateMemoryUsed(self: *Fabric, shard: *Shard, previous: usize) void {
    const current = shard.heap.total_requested_bytes;
    if (current >= previous) {
        _ = self.used_bytes.fetchAdd(current - previous, .monotonic);
    } else {
        _ = self.used_bytes.fetchSub(previous - current, .monotonic);
    }
}

fn checkLimit(self: *Fabric) !void {
    // Historical records can temporarily retain keys that did not coexist live.
    // Concurrent writes may all pass this advisory check before their allocations are accounted.
    if (self.replaying or self.limit == 0 or self.memoryUsed() < self.limit) return;
    self.purgeExpired();
    if (self.memoryUsed() >= self.limit) return error.MemoryLimitExceeded;
}

pub fn put(self: *Fabric, key: []const u8, value: types.ZType) !void {
    return self.putExpiring(key, value, 0);
}

pub fn putExpiring(self: *Fabric, key: []const u8, value: types.ZType, deadline: i64) !void {
    try self.checkLimit();
    const shard = self.shardFor(key);
    shard.lock.lock();
    defer shard.lock.unlock();
    const previous = shard.heap.total_requested_bytes;
    defer self.updateMemoryUsed(shard, previous);
    try shard.put(key, .{ .value = value, .expired_at = deadline });
}

/// Atomically stores all alternating key/value entries only when every key is absent.
pub fn putAllIfAbsent(self: *Fabric, entries: []const types.ZType) !bool {
    if (entries.len == 0 or entries.len & 1 == 1) return error.InvalidArgs;
    const initial_admission = self.checkLimit();
    var pair_index: usize = 0;
    while (pair_index < entries.len) : (pair_index += 2) {
        if (entries[pair_index] != .str) return error.KeyNotString;
    }

    for (self.shards) |*shard| shard.lock.lock();
    defer {
        var index = self.shards.len;
        while (index > 0) {
            index -= 1;
            self.shards[index].lock.unlock();
        }
    }

    var previous = try self.allocator.alloc(usize, self.shards.len);
    defer self.allocator.free(previous);
    for (self.shards, 0..) |*shard, index| previous[index] = shard.heap.total_requested_bytes;
    defer for (self.shards, 0..) |*shard, index| self.updateMemoryUsed(shard, previous[index]);

    pair_index = 0;
    while (pair_index < entries.len) : (pair_index += 2) {
        const key = entries[pair_index].str;
        if (self.liveEntry(self.shardFor(key), key) != null) return false;
    }
    try initial_admission;

    var stored: usize = 0;
    errdefer while (stored > 0) {
        stored -= 2;
        const key = entries[stored].str;
        _ = self.shardFor(key).delete(key);
    };
    while (stored < entries.len) : (stored += 2) {
        const key = entries[stored].str;
        try self.shardFor(key).put(key, .{ .value = entries[stored + 1] });
    }
    return true;
}

pub const GetOrSetResult = struct {
    value: types.ZType,
    inserted: bool,
};

/// Returns an owned copy of the value, inserting the fallback if absent.
pub fn getOrSet(self: *Fabric, key: []const u8, fallback: types.ZType, allocator: std.mem.Allocator) !GetOrSetResult {
    if (self.getCopy(key, allocator)) |value| {
        return .{ .value = value, .inserted = false };
    } else |err| {
        if (err != error.NotFound) return err;
    }

    // The limit check may purge shards, so run it outside the lock and recheck the key.
    const admission = self.checkLimit();
    const shard = self.shardFor(key);
    shard.lock.lock();
    defer shard.lock.unlock();
    if (self.liveEntry(shard, key)) |entry| {
        return .{ .value = try types.ztype_copy(entry.value, allocator), .inserted = false };
    }
    try admission;
    if (fallback == .err) return error.InvalidValue;
    var result = try types.ztype_copy(fallback, allocator);
    errdefer types.ztype_free(&result, allocator);
    const previous = shard.heap.total_requested_bytes;
    defer self.updateMemoryUsed(shard, previous);
    try shard.put(key, .{ .value = fallback });
    return .{ .value = result, .inserted = true };
}

fn liveEntry(self: *const Fabric, shard: *const Shard, key: []const u8) ?Shard.Entry {
    const entry = shard.map.get(key) orelse return null;
    if (entry.expired_at != 0 and entry.isExpired(self.expiryTime())) return null;
    return entry;
}

pub fn expireAt(self: *Fabric, key: []const u8, deadline: i64) bool {
    const shard = self.shardFor(key);
    shard.lock.lock();
    defer shard.lock.unlock();
    const previous = shard.heap.total_requested_bytes;
    defer self.updateMemoryUsed(shard, previous);
    const entry = shard.map.getPtr(key) orelse return false;
    const now = self.expiryTime();
    if (entry.isExpired(now)) {
        _ = shard.delete(key);
        return false;
    }
    if (deadline <= now) return shard.delete(key);
    shard.setExpiry(entry, deadline);
    return true;
}

pub fn persist(self: *Fabric, key: []const u8) bool {
    const shard = self.shardFor(key);
    shard.lock.lock();
    defer shard.lock.unlock();
    const entry = shard.map.getPtr(key) orelse return false;
    if (entry.expired_at == 0) return false;
    if (entry.isExpired(self.expiryTime())) {
        _ = shard.delete(key);
        return false;
    }
    shard.setExpiry(entry, 0);
    return true;
}

pub fn ttl(self: *Fabric, key: []const u8) i64 {
    const shard = self.shardFor(key);
    shard.lock.lockShared();
    defer shard.lock.unlockShared();
    const entry = shard.map.get(key) orelse return -2;
    if (entry.expired_at == 0) return -1;
    const now = self.expiryTime();
    if (entry.isExpired(now)) return -2;
    const remaining = entry.expired_at - now;
    return @divTrunc(remaining, 1000) + @as(i64, @intFromBool(@rem(remaining, 1000) >= 500));
}

pub fn purgeExpired(self: *Fabric) void {
    const now = unixMillis();
    for (self.shards) |*shard| {
        shard.lock.lockShared();
        const has_expiry = shard.expiring != 0;
        shard.lock.unlockShared();
        if (!has_expiry) continue;
        shard.lock.lock();
        const previous = shard.heap.total_requested_bytes;
        shard.purgeExpired(now);
        self.updateMemoryUsed(shard, previous);
        shard.lock.unlock();
    }
}

pub fn get(self: *Fabric, key: []const u8) !types.ZType {
    const shard = self.shardFor(key);
    shard.lock.lockShared();
    defer shard.lock.unlockShared();
    return (self.liveEntry(shard, key) orelse return error.NotFound).value;
}

pub fn getCopy(self: *Fabric, key: []const u8, allocator: std.mem.Allocator) !types.ZType {
    const shard = self.shardFor(key);
    shard.lock.lockShared();
    defer shard.lock.unlockShared();
    return types.ztype_copy((self.liveEntry(shard, key) orelse return error.NotFound).value, allocator);
}

/// Atomically increments or decrements an integer-compatible value.
pub fn increment(self: *Fabric, key: []const u8, delta: i64) !i64 {
    const initial_admission = self.checkLimit();
    const shard = self.shardFor(key);
    shard.lock.lock();
    defer shard.lock.unlock();
    const previous = shard.heap.total_requested_bytes;
    defer self.updateMemoryUsed(shard, previous);

    const entry = self.liveEntry(shard, key);
    const current: i64 = if (entry) |stored| switch (stored.value) {
        .int => |value| value,
        .str, .sstr => |value| std.fmt.parseInt(i64, value, 10) catch return error.InvalidType,
        else => return error.InvalidType,
    } else blk: {
        try initial_admission;
        break :blk 0;
    };
    const result = std.math.add(i64, current, delta) catch return error.InvalidType;
    if (entry) |stored| switch (stored.value) {
        .str => {
            const text = try std.fmt.allocPrint(self.allocator, "{d}", .{result});
            defer self.allocator.free(text);
            try shard.put(key, .{ .value = .{ .str = text }, .expired_at = stored.expired_at });
        },
        .sstr => {
            const text = try std.fmt.allocPrint(self.allocator, "{d}", .{result});
            defer self.allocator.free(text);
            try shard.put(key, .{ .value = .{ .sstr = text }, .expired_at = stored.expired_at });
        },
        else => try shard.put(key, .{ .value = .{ .int = result }, .expired_at = stored.expired_at }),
    } else try shard.put(key, .{ .value = .{ .int = result } });
    return result;
}

/// Atomically appends bytes to a string value and returns the resulting length.
pub fn append(self: *Fabric, key: []const u8, suffix: []const u8) !usize {
    const initial_admission = self.checkLimit();
    const shard = self.shardFor(key);
    shard.lock.lock();
    defer shard.lock.unlock();
    const previous = shard.heap.total_requested_bytes;
    defer self.updateMemoryUsed(shard, previous);

    const entry = self.liveEntry(shard, key);
    const current = if (entry) |stored| switch (stored.value) {
        .str, .sstr => |value| value,
        else => return error.InvalidType,
    } else blk: {
        try initial_admission;
        break :blk "";
    };
    const length = std.math.add(usize, current.len, suffix.len) catch return error.InvalidLength;
    const combined = try self.allocator.alloc(u8, length);
    defer self.allocator.free(combined);
    @memcpy(combined[0..current.len], current);
    @memcpy(combined[current.len..], suffix);
    if (entry) |stored| switch (stored.value) {
        .sstr => try shard.put(key, .{ .value = .{ .sstr = combined }, .expired_at = stored.expired_at }),
        else => try shard.put(key, .{ .value = .{ .str = combined }, .expired_at = stored.expired_at }),
    } else try shard.put(key, .{ .value = .{ .str = combined } });
    return length;
}

pub fn withValue(self: *Fabric, key: []const u8, context: anytype, callback: anytype) !void {
    const shard = self.shardFor(key);
    shard.lock.lockShared();
    defer shard.lock.unlockShared();
    try callback(context, (self.liveEntry(shard, key) orelse return error.NotFound).value);
}

pub fn valueSize(self: *Fabric, key: []const u8) !usize {
    const shard = self.shardFor(key);
    shard.lock.lockShared();
    defer shard.lock.unlockShared();
    return switch ((self.liveEntry(shard, key) orelse return error.NotFound).value) {
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
    const previous = shard.heap.total_requested_bytes;
    defer self.updateMemoryUsed(shard, previous);
    const was_live = self.liveEntry(shard, key) != null;
    _ = shard.delete(key);
    return was_live;
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
    for (self.shards) |*shard| {
        const previous = shard.heap.total_requested_bytes;
        shard.flush();
        self.updateMemoryUsed(shard, previous);
    }
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
    if (!move or destination.len > source.len) try self.checkLimit();

    const source_index = self.shardIndex(source);
    const destination_index = self.shardIndex(destination);
    const first = &self.shards[@min(source_index, destination_index)];
    const second = &self.shards[@max(source_index, destination_index)];
    first.lock.lock();
    defer first.lock.unlock();
    if (first != second) second.lock.lock();
    defer if (first != second) second.lock.unlock();
    const first_previous = first.heap.total_requested_bytes;
    const second_previous = if (first != second) second.heap.total_requested_bytes else 0;
    defer {
        self.updateMemoryUsed(first, first_previous);
        if (first != second) self.updateMemoryUsed(second, second_previous);
    }

    const source_shard = &self.shards[source_index];
    const destination_shard = &self.shards[destination_index];
    const entry = self.liveEntry(source_shard, source) orelse return error.NotFound;
    if (!replace and self.liveEntry(destination_shard, destination) != null) return error.BusyKey;
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
    now: i64,
    shard_index: usize = 0,
    current: ?Shard.Map.Iterator = null,

    pub const Entry = struct {
        key_ptr: *const []const u8,
        value_ptr: *const types.ZType,
        expired_at: i64,
    };

    pub fn next(self: *Iterator) ?Entry {
        while (self.shard_index < self.fabric.shards.len) {
            if (self.current == null)
                self.current = self.fabric.shards[self.shard_index].map.iterator();
            while (self.current.?.next()) |entry| {
                if (entry.value_ptr.isExpired(self.now)) continue;
                return .{ .key_ptr = entry.key_ptr, .value_ptr = &entry.value_ptr.value, .expired_at = entry.value_ptr.expired_at };
            }
            self.shard_index += 1;
            self.current = null;
        }
        return null;
    }

    pub fn count(self: *const Iterator) usize {
        var total: usize = 0;
        for (self.fabric.shards) |*shard| {
            total += shard.map.count();
            if (shard.expiring == 0) continue;
            var iter = shard.map.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.isExpired(self.now)) total -= 1;
            }
        }
        return total;
    }

    pub fn hasExpiry(self: *const Iterator) bool {
        for (self.fabric.shards) |*shard| {
            if (shard.expiring != 0) return true;
        }
        return false;
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
    return .{ .fabric = self, .now = self.expiryTime() };
}

pub fn deinit(self: *Fabric) void {
    for (self.shards) |*shard| shard.deinit();
    self.allocator.free(self.shards);
}
