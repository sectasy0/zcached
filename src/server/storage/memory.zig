const std = @import("std");

const types = @import("../../protocol/types.zig");
const binary = @import("../../protocol/binary.zig");
const TracingAllocator = @import("../tracing.zig");
const persistance = @import("../storage/persistance.zig");

const Logger = @import("../logger.zig");
const Config = @import("../config.zig");
const utils = @import("../utils.zig");

const ZBucket = []const u8;

const Memory = @This();

internal: std.StringHashMap(ZBucket),
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
        .internal = std.StringHashMap(ZBucket).init(allocator),
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
            const bucket = try _encode_alloc(self.allocator, value);

            if (!result.found_existing) {
                const zkey: []u8 = try self.allocator.dupe(u8, key);
                result.key_ptr.* = zkey;
                result.value_ptr.* = bucket;
                return;
            }

            const prev_value = result.value_ptr;
            self.allocator.free(prev_value.*);

            result.value_ptr.* = bucket;
        },
    }
}

pub fn get(self: *Memory, key: []const u8) !types.ZType {
    self.lock.lockShared();
    defer self.lock.unlock();

    const bucket = self.internal.get(key) orelse return error.NotFound;
    const value = try _decode_alloc(self.allocator, bucket);

    return value;
}

pub fn delete(self: *Memory, key: []const u8) bool {
    self.lock.lock();
    defer self.lock.unlock();

    const kv = self.internal.fetchRemove(key) orelse return false;

    self.allocator.free(kv.key);
    self.allocator.free(kv.value);

    return true;
}

pub fn flush(self: *Memory) void {
    self.lock.lock();
    defer self.lock.unlock();

    var iter = self.internal.iterator();
    while (iter.next()) |item| {
        self.allocator.free(item.key_ptr.*);
        self.allocator.free(item.value_ptr.*);
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
    self.lock.lock();
    defer self.lock.unlock();

    // If we are changing the key to a smaller one, it is pointless to block it.
    // The memory usage would be smaller.
    if (new_key.len > key.len and self.is_memory_limit_reached()) return error.MemoryLimitExceeded;

    const entry = self.internal.fetchRemove(key) orelse return error.NotFound;
    const new_key_entry = self.internal.fetchRemove(new_key);

    // Free existing values assigned to 'new_key'
    if (new_key_entry != null) {
        self.allocator.free(new_key_entry.?.key);
        self.allocator.free(new_key_entry.?.value);
    }

    defer self.allocator.free(entry.key);
    // defer ^self.allocator.free(entry.value);

    const zkey: []u8 = try self.allocator.dupe(u8, new_key);
    const zvalue = entry.value;

    self.internal.put(zkey, zvalue) catch return error.InsertFailure;
}

pub fn copy(self: *Memory, source: []const u8, destination: []const u8, replace: bool) !void {
    self.lock.lock();
    defer self.lock.unlock();

    if (self.is_memory_limit_reached()) return error.MemoryLimitExceeded;

    // Value to copy.
    const value: ZBucket = self.internal.get(source) orelse return error.NotFound;
    const destination_result = try self.internal.getOrPut(destination);

    const zvalue: []u8 = try self.allocator.dupe(u8, value);
    errdefer self.allocator.free(zvalue);

    if (destination_result.found_existing) {
        if (replace == false) return error.KeyAlreadyExists;

        // Free old value of the destination key.
        self.allocator.free(destination_result.value_ptr.*);

        destination_result.value_ptr.* = zvalue;
        return;
    }

    const zkey: []u8 = try self.allocator.dupe(u8, destination);

    destination_result.key_ptr.* = zkey;
    destination_result.value_ptr.* = zvalue;
}

fn _encode_alloc(allocator: std.mem.Allocator, value: types.ZType) ![]const u8 {
    var bucket = std.ArrayList(u8).init(allocator);
    defer bucket.deinit();

    const zw = binary.ZWriter.init(bucket.writer().any());
    _ = try zw.write(value);

    return try bucket.toOwnedSlice();
}

fn _decode_alloc(allocator: std.mem.Allocator, zbucket: ZBucket) !types.ZType {
    var bucket = std.io.fixedBufferStream(zbucket);
    const zr = binary.ZReader.init(bucket.reader().any());

    var value: types.ZType = undefined;
    _ = try zr.read(&value, allocator);

    return value;
}

pub fn deinit(self: *Memory) void {
    defer self.internal.deinit();

    var iter = self.internal.iterator();
    while (iter.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        self.allocator.free(entry.value_ptr.*);
    }
}
