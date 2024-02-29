const std = @import("std");

const Config = @import("config.zig");
const types = @import("../protocol/types.zig");
const TracingAllocator = @import("tracing.zig").TracingAllocator;
const PersistanceHandler = @import("persistance.zig").PersistanceHandler;

const log = @import("logger.zig");

const ptrCast = @import("utils.zig").ptrCast;

const MemoryStorage = @This();

internal: std.StringHashMap(types.ZType),
tracing_allocator: std.mem.Allocator,

arena: std.heap.ArenaAllocator,
persister: *PersistanceHandler,

config: Config,

lock: std.Thread.RwLock,

pub fn init(
    tracing_allocator: std.mem.Allocator,
    config: Config,
    persister: *PersistanceHandler,
) MemoryStorage {
    return MemoryStorage{
        .internal = std.StringHashMap(types.ZType).init(tracing_allocator),
        .tracing_allocator = tracing_allocator,
        .arena = std.heap.ArenaAllocator.init(tracing_allocator),
        .config = config,
        .lock = std.Thread.Mutex{},
        .notifier = std.Thread.Condition{},
        .persister = persister,
    };
}

pub fn put(self: *MemoryStorage, key: []const u8, value: types.ZType) !void {
    // const tracking = ptrCast(TracingAllocator, self.tracing_allocator.ptr);

    self.lock.lock();
    defer self.lock.unlock();

    // TODO: remove
    // if (tracking.real_size >= self.config.max_memory and self.config.max_memory != 0) {
    //     return error.MemoryLimitExceeded;
    // }

    switch (value) {
        .err => return error.CantInsertError,
        else => {
            var zkey: []u8 = try self.arena.allocator().dupe(u8, key);
            var zvalue = try types.ztype_copy(value, &self.arena);

            self.internal.put(zkey, zvalue) catch return error.InsertFailure;
        },
    }
}

pub fn get(self: *MemoryStorage, key: []const u8) !types.ZType {
    self.lock.lockShared();
    defer self.lock.unlock();

    return self.internal.get(key) orelse error.NotFound;
}

pub fn delete(self: *MemoryStorage, key: []const u8) bool {
    self.lock.lock();
    defer self.lock.unlock();

    return self.internal.remove(key);
}

pub fn flush(self: *MemoryStorage) void {
    self.lock.lock();
    defer self.lock.unlock();

    self.internal.clearRetainingCapacity();
}

pub fn deinit(self: *MemoryStorage) void {
    self.internal.deinit();
    self.arena.deinit();
}
