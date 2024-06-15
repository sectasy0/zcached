const std = @import("std");

const types = @import("../../protocol/types.zig");
const TracingAllocator = @import("../tracing.zig");
const persistance = @import("../storage/persistance.zig");

const Logger = @import("../logger.zig");
const Config = @import("../config.zig");
const utils = @import("../utils.zig");

const Memory = @This();

internal: std.StringHashMap(types.ZType),
allocator: std.mem.Allocator,

persister: *persistance.Handler,

config: Config,

lock: std.Thread.RwLock,

last_save: i64,

pub fn init(
    allocator: std.mem.Allocator,
    config: Config,
    persister: *persistance.Handler,
) Memory {
    return Memory{
        .internal = std.StringHashMap(types.ZType).init(allocator),
        .allocator = allocator,
        .config = config,
        .lock = std.Thread.RwLock{},
        .persister = persister,
        .last_save = std.time.timestamp(),
    };
}

fn is_memory_limit_reached(self: *Memory) bool {
    const tracking = utils.ptrCast(TracingAllocator, self.allocator.ptr);
    if (tracking.real_size >= self.config.maxmemory and self.config.maxmemory != 0) {
        return true;
    }
    return false;
}

pub fn put(self: *Memory, key: []const u8, value: types.ZType) !void {
    self.lock.lock();
    defer self.lock.unlock();

    if (self.is_memory_limit_reached()) return error.MemoryLimitExceeded;

    switch (value) {
        .err => return error.InvalidValue,
        else => {
            const result = try self.internal.getOrPut(key);
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

pub fn get(self: *Memory, key: []const u8) !types.ZType {
    self.lock.lockShared();
    defer self.lock.unlock();

    return self.internal.get(key) orelse error.NotFound;
}

pub fn delete(self: *Memory, key: []const u8) bool {
    self.lock.lock();
    defer self.lock.unlock();

    const kv = self.internal.fetchRemove(key) orelse return false;

    var zkey: types.ZType = .{ .str = @constCast(kv.key) };
    types.ztype_free(
        &zkey,
        self.allocator,
    );

    var zvalue: types.ZType = kv.value;
    types.ztype_free(&zvalue, self.allocator);

    return true;
}

pub fn flush(self: *Memory) void {
    self.lock.lock();
    defer self.lock.unlock();

    var iter = self.internal.iterator();
    while (iter.next()) |item| {
        var key = .{ .str = @constCast(item.key_ptr.*) };
        var value = item.value_ptr.*;

        types.ztype_free(&key, self.allocator);
        types.ztype_free(&value, self.allocator);
    }

    self.internal.clearRetainingCapacity();
}

pub fn size(self: *Memory) i64 {
    self.lock.lockShared();
    defer self.lock.unlock();

    return self.internal.count();
}

pub fn save(self: *Memory) !usize {
    self.lock.lockShared();
    defer self.lock.unlock();

    return try self.persister.save(self);
}

pub fn keys(self: *Memory) !std.ArrayList(types.ZType) {
    self.lock.lockShared();
    defer self.lock.unlock();

    var result = std.ArrayList(types.ZType).init(self.allocator);

    var iter = self.internal.keyIterator();
    while (iter.next()) |key| {
        const zkey: types.ZType = .{ .str = @constCast(key.*) };
        try result.append(zkey);
    }

    return result;
}

pub fn rename(self: *Memory, key: []const u8, new_key: []const u8) !void {
    self.lock.lockShared();
    defer self.lock.unlock();

    // If we are changing the key to a smaller one, it is pointless to block it.
    // The memory usage would be smaller.
    if (new_key.len > key.len and self.is_memory_limit_reached()) return error.MemoryLimitExceeded;

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

pub fn copy(self: *Memory, source: []const u8, destination: []const u8, replace: bool) !void {
    self.lock.lockShared();
    defer self.lock.unlock();
    if (self.is_memory_limit_reached()) return error.MemoryLimitExceeded;

    // Value to copy.
    const value: types.ZType = self.internal.get(source) orelse return error.NotFound;
    const destination_result = try self.internal.getOrPut(destination);

    if (destination_result.found_existing) {
        if (replace == false) return error.KeyAlreadyExists;

        const zvalue = try types.ztype_copy(value, self.allocator);
        const previous_value: *types.ZType = destination_result.value_ptr;

        // Free old value of this key and set new, from source key.
        types.ztype_free(previous_value, self.allocator);
        destination_result.value_ptr.* = zvalue;
        return;
    }
    const zvalue = try types.ztype_copy(value, self.allocator);
    const zkey: []u8 = try self.allocator.dupe(u8, destination);

    destination_result.key_ptr.* = zkey;
    destination_result.value_ptr.* = zvalue;
}

pub fn deinit(self: *Memory) void {
    var value = .{ .map = self.internal };

    types.ztype_free(
        &value,
        self.allocator,
    );
}
