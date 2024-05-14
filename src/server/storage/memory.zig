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

pub fn put(self: *Memory, key: []const u8, value: types.ZType) !void {
    const tracking = utils.ptr_cast(TracingAllocator, self.allocator.ptr);

    self.lock.lock();
    defer self.lock.unlock();

    if (tracking.real_size >= self.config.maxmemory and self.config.maxmemory != 0) {
        return error.MemoryLimitExceeded;
    }

    switch (value) {
        .err => return error.CantInsertError,
        else => {
            const zkey: []u8 = try self.allocator.dupe(u8, key);
            const zvalue = try types.ztype_copy(value, self.allocator);

            self.internal.put(zkey, zvalue) catch return error.InsertFailure;
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

pub fn deinit(self: *Memory) void {
    var value = .{ .map = self.internal };

    types.ztype_free(
        &value,
        self.allocator,
    );
}
