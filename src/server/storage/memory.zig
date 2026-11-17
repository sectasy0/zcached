//! Thread-safe in-memory key/value storage and snapshot access.
const std = @import("std");
const runtime_io = @import("runtime_io");
const sync = @import("sync");

const types = @import("../../protocol/types.zig");
const TracingAllocator = @import("../tracing.zig");
const persistance = @import("../storage/persistance.zig");

const Logger = @import("../logger.zig");
const Config = @import("../config.zig");
const utils = @import("../utils.zig");

/// Thread-safe in-memory key/value store with persistence and memory-limit support.
const Memory = @This();

/// Owns the stored keys and values.
internal: std.StringHashMap(types.ZType),
/// Allocator used for stored data and returned key collections.
allocator: std.mem.Allocator,

/// Persister used to write consistent snapshots of the store.
persister: *persistance.Handler,

/// Runtime settings that affect storage limits and persistence behavior.
config: Config,

/// Protects the map and its owned values from concurrent access.
lock: sync.RwLock,

/// Timestamp associated with the most recent successful save.
last_save: i64,

/// Creates an empty store using the supplied allocator, config, and persister.
pub fn init(
    allocator: std.mem.Allocator,
    config: Config,
    persister: *persistance.Handler,
) Memory {
    return Memory{
        .internal = std.StringHashMap(types.ZType).init(allocator),
        .allocator = allocator,
        .config = config,
        .lock = .{},
        .persister = persister,
        .last_save = runtime_io.timestamp(),
    };
}

/// Reports whether tracked allocations have reached the configured limit.
fn isMemoryLimitReached(self: *Memory) bool {
    if (self.config.max_memory == 0) return false;

    const tracking = utils.ptrCast(TracingAllocator, self.allocator.ptr);
    return tracking.real_size >= self.config.max_memory;
}

/// Inserts or replaces a value, preserving owned storage for compatible strings.
pub fn put(self: *Memory, key: []const u8, value: types.ZType) !void {
    self.lock.lock();
    defer self.lock.unlock();

    if (self.isMemoryLimitReached()) return error.MemoryLimitExceeded;

    switch (value) {
        .err => return error.InvalidValue,
        else => {
            const result = try self.internal.getOrPut(key);
            const stored_bytes: ?[]const u8 = if (result.found_existing) switch (result.value_ptr.*) {
                .str => |bytes| bytes,
                .sstr => |bytes| bytes,
                else => null,
            } else null;
            const incoming_bytes: ?[]const u8 = switch (value) {
                .str => |bytes| bytes,
                .sstr => |bytes| bytes,
                else => null,
            };

            // Same-kind, same-size strings can reuse their buffer without changing the response type.
            if (stored_bytes != null and incoming_bytes != null and
                std.meta.activeTag(result.value_ptr.*) == std.meta.activeTag(value) and
                stored_bytes.?.len == incoming_bytes.?.len)
            {
                const stored = stored_bytes.?;
                const incoming = incoming_bytes.?;
                if (!std.mem.eql(u8, stored, incoming)) {
                    @memmove(@constCast(stored), incoming);
                }
                return;
            }
            const zvalue = try types.ztype_copy(value, self.allocator);

            if (!result.found_existing) {
                const zkey: []u8 = try self.allocator.dupe(u8, key);
                result.key_ptr.* = zkey;
                result.value_ptr.* = zvalue;
                return;
            }

            const prev_value = result.value_ptr;

            types.ztype_free(prev_value, self.allocator);

            result.value_ptr.* = zvalue;
        },
    }
}

/// Returns a borrowed value; callers must not retain it across concurrent mutations.
pub fn get(self: *Memory, key: []const u8) !types.ZType {
    self.lock.lockShared();
    defer self.lock.unlockShared();

    return self.internal.get(key) orelse error.NotFound;
}

/// Returns an independent copy of a stored value allocated with `allocator`.
pub fn getCopy(self: *Memory, key: []const u8, allocator: std.mem.Allocator) !types.ZType {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    const value = self.internal.get(key) orelse return error.NotFound;
    return types.ztype_copy(value, allocator);
}

/// Calls `callback` with a borrowed value while holding the store's shared lock.
pub fn withValue(self: *Memory, key: []const u8, context: anytype, callback: anytype) !void {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    const value = self.internal.get(key) orelse return error.NotFound;
    try callback(context, value);
}

/// Returns a value's byte length, collection count, or scalar storage size.
pub fn valueSize(self: *Memory, key: []const u8) !usize {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    const value = self.internal.get(key) orelse return error.NotFound;
    return switch (value) {
        .str, .sstr => |text| text.len,
        .array => |array| array.items.len,
        inline .map, .set, .uset => |collection| collection.count(),
        inline .int, .float, .bool => |scalar| @sizeOf(@TypeOf(scalar)),
        else => 0,
    };
}

/// Removes a key and frees its owned key and value; returns false if absent.
pub fn delete(self: *Memory, key: []const u8) bool {
    self.lock.lock();
    defer self.lock.unlock();

    const kv = self.internal.fetchRemove(key) orelse return false;

    var zkey: types.ZType = .{ .str = kv.key };
    types.ztype_free(
        &zkey,
        self.allocator,
    );

    var zvalue: types.ZType = kv.value;
    types.ztype_free(&zvalue, self.allocator);

    return true;
}

/// Removes all entries while retaining the map's allocated capacity.
pub fn flush(self: *Memory) void {
    self.lock.lock();
    defer self.lock.unlock();

    var iter = self.internal.iterator();
    while (iter.next()) |item| {
        var key: types.ZType = .{ .str = item.key_ptr.* };
        var value = item.value_ptr.*;

        types.ztype_free(&key, self.allocator);
        types.ztype_free(&value, self.allocator);
    }

    self.internal.clearRetainingCapacity();
}

/// Returns the number of entries currently stored.
pub fn size(self: *Memory) i64 {
    self.lock.lockShared();
    defer self.lock.unlockShared();

    return self.internal.count();
}

/// Writes a consistent snapshot through the configured persister.
pub fn save(self: *Memory) !usize {
    self.lock.lockShared();
    defer self.lock.unlockShared();

    return try self.persister.save(self);
}

/// Returns keys backed by the store's allocations; key slices are borrowed.
pub fn keys(self: *Memory) !std.array_list.Managed(types.ZType) {
    self.lock.lockShared();
    defer self.lock.unlockShared();

    var result = std.array_list.Managed(types.ZType).init(self.allocator);

    var iter = self.internal.keyIterator();
    while (iter.next()) |key| {
        const zkey: types.ZType = .{ .str = key.* };
        try result.append(zkey);
    }

    return result;
}

/// Returns independently allocated copies of all keys.
pub fn keysCopy(self: *Memory, allocator: std.mem.Allocator) !types.ZType.Array {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    var result = try types.ZType.Array.initCapacity(allocator, self.internal.count());
    errdefer {
        for (result.items) |*key| types.ztype_free(key, allocator);
        result.deinit();
    }
    var key_iterator = self.internal.keyIterator();
    while (key_iterator.next()) |key| {
        result.appendAssumeCapacity(.{ .str = try allocator.dupe(u8, key.*) });
    }
    return result;
}

/// Moves a value to `new_key`, replacing any value already stored there.
pub fn rename(self: *Memory, key: []const u8, new_key: []const u8) !void {
    self.lock.lock();
    defer self.lock.unlock();

    // If we are changing the key to a smaller one, it is pointless to block it.
    // The memory usage would be smaller.
    if (new_key.len > key.len and self.isMemoryLimitReached()) return error.MemoryLimitExceeded;

    var entry = self.internal.fetchRemove(key) orelse return error.NotFound;
    var new_key_entry = self.internal.fetchRemove(new_key);

    // Free existing values assigned to 'new_key'
    if (new_key_entry != null) {
        self.allocator.free(new_key_entry.?.key);
        types.ztype_free(&new_key_entry.?.value, self.allocator);
    }

    defer {
        self.allocator.free(entry.key);
        types.ztype_free(&entry.value, self.allocator);
    }

    const zkey: []u8 = try self.allocator.dupe(u8, new_key);
    const zvalue = try types.ztype_copy(entry.value, self.allocator);

    self.internal.put(zkey, zvalue) catch return error.InsertFailure;
}

/// Copies a value to `destination`, optionally replacing an existing entry.
pub fn copy(self: *Memory, source: []const u8, destination: []const u8, replace: bool) !void {
    self.lock.lock();
    defer self.lock.unlock();

    if (self.isMemoryLimitReached()) return error.MemoryLimitExceeded;

    // Value to copy.
    const value: types.ZType = self.internal.get(source) orelse return error.NotFound;
    const destination_result = try self.internal.getOrPut(destination);

    if (destination_result.found_existing) {
        if (replace == false) return error.BusyKey;

        // Free old value of the destination key.
        types.ztype_free(destination_result.value_ptr, self.allocator);

        destination_result.value_ptr.* = try types.ztype_copy(value, self.allocator);
        return;
    }
    const zvalue: types.ZType = try types.ztype_copy(value, self.allocator);
    const zkey: []u8 = try self.allocator.dupe(u8, destination);

    destination_result.key_ptr.* = zkey;
    destination_result.value_ptr.* = zvalue;
}

/// Starts a shared-locked map iteration; the caller must unlock after iteration.
pub fn iterator(self: *Memory) @TypeOf(self.internal.iterator()) {
    self.lock.lockShared();

    return self.internal.iterator();
}

/// Releases all values and map storage owned by this store.
pub fn deinit(self: *Memory) void {
    var value: types.ZType = .{ .map = self.internal };

    types.ztype_free(
        &value,
        self.allocator,
    );
}
