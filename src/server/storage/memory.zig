//! Storage facade over the sharded in-memory fabric and snapshot persistence.
const std = @import("std");
const runtime_io = @import("runtime_io");
const types = @import("../../protocol/types.zig");
const persistance = @import("persistance.zig");
const Config = @import("../config.zig");
pub const Fabric = @import("fabric.zig");

const Memory = @This();

fabric: Fabric,
allocator: std.mem.Allocator,
persister: *persistance.Handler,
config: Config,
last_save: std.atomic.Value(i64),

pub fn init(allocator: std.mem.Allocator, config: Config, persister: *persistance.Handler) !Memory {
    var settings = config.memory;
    if (settings.limit == 0) settings.limit = config.max_memory;
    return .{
        .fabric = try Fabric.init(allocator, settings),
        .allocator = allocator,
        .config = config,
        .persister = persister,
        .last_save = .init(runtime_io.timestamp()),
    };
}

pub fn put(self: *Memory, key: []const u8, value: types.ZType) !void {
    return self.fabric.put(key, value);
}

pub const unixMillis = Fabric.unixMillis;

pub fn putExpiring(self: *Memory, key: []const u8, value: types.ZType, deadline: i64) !void {
    return self.fabric.putExpiring(key, value, deadline);
}

pub fn expireAt(self: *Memory, key: []const u8, deadline: i64) bool {
    return self.fabric.expireAt(key, deadline);
}

pub fn persist(self: *Memory, key: []const u8) bool {
    return self.fabric.persist(key);
}

pub fn ttl(self: *Memory, key: []const u8) i64 {
    return self.fabric.ttl(key);
}

pub fn purgeExpired(self: *Memory) void {
    self.fabric.purgeExpired();
}

/// Returns a borrowed value; do not retain it across concurrent mutations.
pub fn get(self: *Memory, key: []const u8) !types.ZType {
    return self.fabric.get(key);
}

pub fn getCopy(self: *Memory, key: []const u8, allocator: std.mem.Allocator) !types.ZType {
    return self.fabric.getCopy(key, allocator);
}

pub fn withValue(self: *Memory, key: []const u8, context: anytype, callback: anytype) !void {
    return self.fabric.withValue(key, context, callback);
}

pub fn valueSize(self: *Memory, key: []const u8) !usize {
    return self.fabric.valueSize(key);
}

pub fn delete(self: *Memory, key: []const u8) bool {
    return self.fabric.delete(key);
}

pub fn flush(self: *Memory) void {
    self.fabric.flush();
}

pub fn size(self: *Memory) i64 {
    return @intCast(self.fabric.size());
}

pub fn save(self: *Memory) !usize {
    return self.persister.save(self);
}

/// The returned list owns its buffer, but borrows the stored key bytes.
pub fn keys(self: *Memory) !types.ZType.Array {
    return self.fabric.keys(self.allocator);
}

pub fn keysCopy(self: *Memory, allocator: std.mem.Allocator) !types.ZType.Array {
    return self.fabric.keysCopy(allocator);
}

pub fn rename(self: *Memory, key: []const u8, new_key: []const u8) !void {
    return self.fabric.rename(key, new_key);
}

pub fn copy(self: *Memory, source: []const u8, destination: []const u8, replace: bool) !void {
    return self.fabric.copy(source, destination, replace);
}

/// Holds all shard shared locks until the returned iterator is deinitialized.
pub fn iterator(self: *Memory) Fabric.Iterator {
    return self.fabric.iterator();
}

pub fn deinit(self: *Memory) void {
    self.fabric.deinit();
}
