const std = @import("std");

const Config = @import("config.zig").Config;
const types = @import("../protocol/types.zig");
const TracingAllocator = @import("tracing.zig").TracingAllocator;
const PersistanceHandler = @import("persistance.zig").PersistanceHandler;

const log = @import("logger.zig");

const ptrCast = @import("utils.zig").ptrCast;

pub const MemoryStorage = struct {
    internal: std.StringHashMap(types.ZType),
    tracing_allocator: std.mem.Allocator,

    arena: std.heap.ArenaAllocator,

    persister: *PersistanceHandler,

    config: Config,

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
            .persister = persister,
        };
    }

    pub fn put(self: *MemoryStorage, key: []const u8, value: types.ZType) !void {
        const tracking = ptrCast(TracingAllocator, self.tracing_allocator.ptr);

        if (tracking.real_size >= self.config.max_memory and self.config.max_memory != 0) {
            return error.MemoryLimitExceeded;
        }

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
        const value = self.internal.get(key);
        if (value == null) return error.NotFound;
        return value.?;
    }

    pub fn delete(self: *MemoryStorage, key: []const u8) bool {
        return self.internal.remove(key);
    }

    pub fn flush(self: *MemoryStorage) void {
        self.internal.clearRetainingCapacity();
    }

    pub fn deinit(self: *MemoryStorage) void {
        self.internal.deinit();
        self.arena.deinit();
    }
};

test "should get existing and not get non-existing key" {
    var config = try Config.load(std.testing.allocator, null, null);
    defer config.deinit();

    var logger = try log.Logger.init(std.testing.allocator, null);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        null,
    );

    defer persister.deinit();

    var tracing_allocator = TracingAllocator.init(std.testing.allocator);
    var storage = MemoryStorage.init(
        tracing_allocator.allocator(),
        config,
        &persister,
    );
    defer storage.deinit();

    var string = "Was wir wissen, ist ein Tropfen, was wir nicht wissen, ein Ozean.";
    var value: types.ZType = .{ .str = @constCast(string) };

    try storage.put("foo", .{ .int = 42 });
    try storage.put("foo2", .{ .float = 123.45 });
    try storage.put("foo3", .{ .bool = true });
    try storage.put("foo4", .{ .null = void{} });
    try storage.put("foo5", .{ .sstr = @constCast("simple string") });
    try storage.put("bar", value);

    // need to create function that checks for equality of these things
    try std.testing.expectEqual(storage.get("foo"), .{ .int = 42 });
    try std.testing.expectEqual(storage.get("foo2"), .{ .float = 123.45 });
    try std.testing.expectEqual(storage.get("foo3"), .{ .bool = true });
    try std.testing.expectEqual(storage.get("foo4"), .{ .null = void{} });
    // we have to compare values cause it's not same place in memory
    try std.testing.expectEqualStrings((try storage.get("foo5")).sstr, @constCast("simple string"));
    try std.testing.expectEqualStrings((try storage.get("bar")).str, value.str);

    // array
    var array = std.ArrayList(types.ZType).init(std.testing.allocator);
    try array.append(.{ .str = @constCast(string) });
    try array.append(.{ .sstr = @constCast("simple string") });
    try array.append(.{ .int = 47 });
    try array.append(.{ .float = 47.47 });
    try array.append(.{ .bool = false });
    try array.append(.{ .null = void{} });
    defer array.deinit();

    try storage.put("foo6", .{ .array = array });

    const getted = try storage.get("foo6");
    for (getted.array.items) |item| {
        switch (item) {
            .str => try std.testing.expectEqualStrings(item.str, @constCast(string)),
            .sstr => try std.testing.expectEqualStrings(item.sstr, @constCast("simple string")),
            .int => try std.testing.expectEqual(item, .{ .int = 47 }),
            .float => try std.testing.expectEqual(item, .{ .float = 47.47 }),
            .bool => try std.testing.expectEqual(item, .{ .bool = false }),
            .null => try std.testing.expectEqual(item, .{ .null = void{} }),
            else => unreachable,
        }
    }

    // map
    var map = std.StringHashMap(types.ZType).init(std.testing.allocator);
    try map.put("test5", .{ .str = @constCast(string) });
    try map.put("test6", .{ .sstr = @constCast("simple string") });
    try map.put("test1", .{ .int = 88 });
    try map.put("test2", .{ .float = 88.45 });
    try map.put("test3", .{ .bool = true });
    try map.put("test4", .{ .null = void{} });
    defer map.deinit();

    try storage.put("foo7", .{ .map = map });

    var iter = map.iterator();
    while (iter.next()) |item| {
        switch (item.value_ptr.*) {
            .str => try std.testing.expectEqualStrings(item.value_ptr.*.str, @constCast(string)),
            .sstr => try std.testing.expectEqualStrings(item.value_ptr.*.sstr, @constCast("simple string")),
            .int => try std.testing.expectEqual(item.value_ptr.*, .{ .int = 88 }),
            .float => try std.testing.expectEqual(item.value_ptr.*, .{ .float = 88.45 }),
            .bool => try std.testing.expectEqual(item.value_ptr.*, .{ .bool = true }),
            .null => try std.testing.expectEqual(item.value_ptr.*, .{ .null = void{} }),
            else => unreachable,
        }
    }

    try std.testing.expectEqual(storage.get("baz"), error.NotFound);
}

test "should delete existing key" {
    var config = try Config.load(std.testing.allocator, null, null);
    defer config.deinit();

    var logger = try log.Logger.init(std.testing.allocator, null);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        null,
    );

    defer persister.deinit();

    var tracing_allocator = TracingAllocator.init(std.testing.allocator);
    var storage = MemoryStorage.init(
        tracing_allocator.allocator(),
        config,
        &persister,
    );
    defer storage.deinit();

    var string = "Die meisten Menschen sind nichts als Bauern auf einem Schachbrett, das von einer unbekannten Hand geführt wird.";
    var value: types.ZType = .{ .str = @constCast(string) };

    try storage.put("foo", .{ .int = 42 });
    try storage.put("bar", value);

    try std.testing.expectEqual(storage.delete("foo"), true);
    try std.testing.expectEqual(storage.get("foo"), error.NotFound);
    try std.testing.expectEqualStrings((try storage.get("bar")).str, value.str);
}

test "should not delete non-existing key" {
    var config = try Config.load(std.testing.allocator, null, null);
    defer config.deinit();

    var logger = try log.Logger.init(std.testing.allocator, null);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        null,
    );

    defer persister.deinit();

    var tracing_allocator = TracingAllocator.init(std.testing.allocator);
    var storage = MemoryStorage.init(
        tracing_allocator.allocator(),
        config,
        &persister,
    );
    defer storage.deinit();

    try std.testing.expectEqual(storage.delete("foo"), false);
}

test "should flush storage" {
    var config = try Config.load(std.testing.allocator, null, null);
    defer config.deinit();

    var logger = try log.Logger.init(std.testing.allocator, null);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        null,
    );

    defer persister.deinit();

    var tracing_allocator = TracingAllocator.init(std.testing.allocator);
    var storage = MemoryStorage.init(
        tracing_allocator.allocator(),
        config,
        &persister,
    );
    defer storage.deinit();

    var string = "Es gibt Momente im Leben, da muss man verstehen, dass die Entscheidungen, die man trifft, nicht nur das eigene Schicksal angehen.";
    var value: types.ZType = .{
        .str = @constCast(string),
    };

    try storage.put("foo", .{ .int = 42 });
    try storage.put("bar", value);

    storage.flush();

    try std.testing.expectEqual(storage.get("foo"), error.NotFound);
    try std.testing.expectEqual(storage.get("bar"), error.NotFound);
}

test "should not store error" {
    var config = try Config.load(std.testing.allocator, null, null);
    defer config.deinit();

    var logger = try log.Logger.init(std.testing.allocator, null);

    var persister = try PersistanceHandler.init(
        std.testing.allocator,
        config,
        logger,
        null,
    );

    defer persister.deinit();

    var tracing_allocator = TracingAllocator.init(std.testing.allocator);
    var storage = MemoryStorage.init(
        tracing_allocator.allocator(),
        config,
        &persister,
    );
    defer storage.deinit();

    const err_value = .{ .err = .{ .message = "random error" } };
    try std.testing.expectEqual(storage.put("test", err_value), error.CantInsertError);
}

// commented for now because i changed allocator to arena and i have to
// figure out how to trace bytes inside it.
// test "should return error.MemoryLimitExceeded" {
//     var config = try Config.load(std.testing.allocator, null, null);
//     defer config.deinit();
//     config.max_memory = 1048576; // 1 megabyte
//
//     var logger = try log.Logger.init(std.testing.allocator, null);
//
//     var persister = try PersistanceHandler.init(
//         std.testing.allocator,
//         config,
//         logger,
//         null,
//     );
//
//     defer persister.deinit();
//
//     var tracing_allocator = TracingAllocator.init(std.testing.allocator);
//     var storage = MemoryStorage.init(tracing_allocator.allocator(), config, &persister,);
//     defer storage.deinit();
//
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();
//
//     var string = "Was wir wissen, ist ein Tropfen, was wir nicht wissen, ein Ozean.";
//     var value: types.ZType = .{ .str = @constCast(string) };
//     for (0..6554) |i| {
//         var key = try std.fmt.allocPrint(arena.allocator(), "key-{d}", .{i});
//         try storage.put(key, value);
//     }
//
//     try std.testing.expectEqual(storage.put("test key", value), error.MemoryLimitExceeded);
// }
