const std = @import("std");

const storage = @import("storage.zig");
const AnyType = @import("../protocol/types.zig").AnyType;
const Config = @import("config.zig").Config;
const utils = @import("utils.zig");
const log = @import("logger.zig");

const TracingAllocator = @import("tracing.zig").TracingAllocator;

const Commands = enum {
    PING,
    GET,
    SET,
    DELETE,
    FLUSH,
    MGET,
    MSET,
    DBSIZE,
};
pub const CMDHandler = struct {
    allocator: std.mem.Allocator,
    storage: *storage.MemoryStorage,

    logger: *const log.Logger,

    const HandlerResult = union(enum) { ok: AnyType, err: anyerror };

    pub fn init(
        allocator: std.mem.Allocator,
        mstorage: *storage.MemoryStorage,
        logger: *const log.Logger,
    ) CMDHandler {
        return CMDHandler{
            .allocator = allocator,
            .storage = mstorage,
            .logger = logger,
        };
    }

    pub fn process(self: *CMDHandler, command_set: *const std.ArrayList(AnyType)) HandlerResult {
        if (command_set.capacity == 0) return .{ .err = error.UnknownCommand };

        // first element in command_set is command name and should be always str
        if (std.meta.activeTag(command_set.items[0]) != .str) {
            return .{ .err = error.UnknownCommand };
        }

        var cmd_upper: []u8 = utils.to_uppercase(command_set.items[0].str);
        const command_type = std.meta.stringToEnum(Commands, cmd_upper) orelse {
            return .{ .err = error.UnknownCommand };
        };
        try switch (command_type) {
            .PING => return self.ping(),
            .GET => return self.get(command_set.items[1]),
            .SET => {
                // second element in command_set is key and should be always str
                if (std.meta.activeTag(command_set.items[1]) != .str) {
                    return .{ .err = error.KeyNotString };
                }

                return self.set(command_set.items[1], command_set.items[2]);
            },
            .DELETE => return self.delete(command_set.items[1]),
            .FLUSH => return self.flush(),
            .DBSIZE => return .{ .ok = .{ .int = self.storage.internal.count() } },
            // .MGET => mget(command_set.items[1]),
            // .MSET => mset(command_set.items[1], command_set.items[2]),
            else => return .{ .err = error.UnknownCommand },
        };
    }

    fn get(self: *CMDHandler, key: AnyType) HandlerResult {
        const value = self.storage.get(key.str) catch |err| {
            return .{ .err = err };
        };

        return .{ .ok = value };
    }

    fn set(self: *CMDHandler, key: AnyType, value: AnyType) HandlerResult {
        self.storage.put(key.str, value) catch |err| {
            return .{ .err = err };
        };

        return .{ .ok = .{ .sstr = @constCast("OK") } };
    }

    fn delete(self: *CMDHandler, key: AnyType) HandlerResult {
        const result = self.storage.delete(key.str);

        if (result) {
            return .{ .ok = .{ .sstr = @constCast("OK") } };
        } else {
            return .{ .err = error.NotFound };
        }
    }

    fn flush(self: *CMDHandler) HandlerResult {
        self.storage.flush();
        return .{ .ok = .{ .null = void{} } };
    }

    fn ping(self: *CMDHandler) HandlerResult {
        _ = self;
        return .{ .ok = .{ .sstr = @constCast("PONG") } };
    }
};

test "should handle SET command" {
    const config = try Config.load(std.testing.allocator, null, null);
    var tracing_allocator = TracingAllocator.init(std.testing.allocator);
    var mstorage = storage.MemoryStorage.init(tracing_allocator.allocator(), config);
    defer mstorage.deinit();

    const logger = log.Logger.init(std.testing.allocator, null) catch |err| {
        std.log.err("# failed to initialize logger: {}", .{err});
        return;
    };
    var cmd_handler = CMDHandler.init(std.testing.allocator, &mstorage, &logger);

    var command_set = std.ArrayList(AnyType).init(std.testing.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("SET") });
    try command_set.append(.{ .str = @constCast("key") });
    try command_set.append(.{ .str = @constCast("value") });

    var result = cmd_handler.process(&command_set);

    try std.testing.expectEqual(result.ok, .{ .sstr = @constCast("OK") });
    try std.testing.expectEqual(mstorage.get("key"), .{ .str = @constCast("value") });
}

test "should handle GET command" {
    const config = try Config.load(std.testing.allocator, null, null);
    var tracing_allocator = TracingAllocator.init(std.testing.allocator);
    var mstorage = storage.MemoryStorage.init(tracing_allocator.allocator(), config);
    defer mstorage.deinit();
    try mstorage.put("key", .{ .str = @constCast("value") });

    const logger = log.Logger.init(std.testing.allocator, null) catch |err| {
        std.log.err("# failed to initialize logger: {}", .{err});
        return;
    };
    var cmd_handler = CMDHandler.init(std.testing.allocator, &mstorage, &logger);

    var command_set = std.ArrayList(AnyType).init(std.testing.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("GET") });
    try command_set.append(.{ .str = @constCast("key") });

    var result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result, .{ .ok = .{ .str = @constCast("value") } });
}

test "should handle DELETE command" {
    const config = try Config.load(std.testing.allocator, null, null);
    var tracing_allocator = TracingAllocator.init(std.testing.allocator);
    var mstorage = storage.MemoryStorage.init(tracing_allocator.allocator(), config);
    defer mstorage.deinit();
    try mstorage.put("key", .{ .str = @constCast("value") });
    try std.testing.expectEqual(mstorage.get("key"), .{ .str = @constCast("value") });

    const logger = log.Logger.init(std.testing.allocator, null) catch |err| {
        std.log.err("# failed to initialize logger: {}", .{err});
        return;
    };
    var cmd_handler = CMDHandler.init(std.testing.allocator, &mstorage, &logger);

    var command_set = std.ArrayList(AnyType).init(std.testing.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("DELETE") });
    try command_set.append(.{ .str = @constCast("key") });

    var result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result, .{ .ok = .{ .sstr = @constCast("OK") } });
    try std.testing.expectEqual(mstorage.get("key"), error.NotFound);
}

test "should return error.NotFound for non existing during DELETE command" {
    const config = try Config.load(std.testing.allocator, null, null);
    var tracing_allocator = TracingAllocator.init(std.testing.allocator);
    var mstorage = storage.MemoryStorage.init(tracing_allocator.allocator(), config);
    defer mstorage.deinit();

    const logger = log.Logger.init(std.testing.allocator, null) catch |err| {
        std.log.err("# failed to initialize logger: {}", .{err});
        return;
    };
    var cmd_handler = CMDHandler.init(std.testing.allocator, &mstorage, &logger);

    var command_set = std.ArrayList(AnyType).init(std.testing.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("DELETE") });
    try command_set.append(.{ .str = @constCast("key") });

    var result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result, .{ .err = error.NotFound });
}

test "should handle FLUSH command" {
    const config = try Config.load(std.testing.allocator, null, null);
    var tracing_allocator = TracingAllocator.init(std.testing.allocator);
    var mstorage = storage.MemoryStorage.init(tracing_allocator.allocator(), config);
    defer mstorage.deinit();

    try mstorage.put("key", .{ .str = @constCast("value") });
    try mstorage.put("key2", .{ .str = @constCast("value2") });

    const logger = log.Logger.init(std.testing.allocator, null) catch |err| {
        std.log.err("# failed to initialize logger: {}", .{err});
        return;
    };
    var cmd_handler = CMDHandler.init(std.testing.allocator, &mstorage, &logger);

    var command_set = std.ArrayList(AnyType).init(std.testing.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("FLUSH") });

    var result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.ok, .{ .null = void{} });
    try std.testing.expectEqual(mstorage.internal.count(), 0);
}

test "should handle PING command" {
    const config = try Config.load(std.testing.allocator, null, null);
    var tracing_allocator = TracingAllocator.init(std.testing.allocator);
    var mstorage = storage.MemoryStorage.init(tracing_allocator.allocator(), config);
    defer mstorage.deinit();

    try mstorage.put("key", .{ .str = @constCast("value") });
    try mstorage.put("key2", .{ .str = @constCast("value2") });

    const logger = log.Logger.init(std.testing.allocator, null) catch |err| {
        std.log.err("# failed to initialize logger: {}", .{err});
        return;
    };
    var cmd_handler = CMDHandler.init(std.testing.allocator, &mstorage, &logger);

    var command_set = std.ArrayList(AnyType).init(std.testing.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("PING") });

    var result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.ok, .{ .sstr = @constCast("PONG") });
}

test "should handle DBSIZE command" {
    const config = try Config.load(std.testing.allocator, null, null);
    var tracing_allocator = TracingAllocator.init(std.testing.allocator);
    var mstorage = storage.MemoryStorage.init(tracing_allocator.allocator(), config);
    defer mstorage.deinit();

    try mstorage.put("key", .{ .str = @constCast("value") });
    try mstorage.put("key2", .{ .str = @constCast("value2") });

    const logger = log.Logger.init(std.testing.allocator, null) catch |err| {
        std.log.err("# failed to initialize logger: {}", .{err});
        return;
    };
    var cmd_handler = CMDHandler.init(std.testing.allocator, &mstorage, &logger);

    var command_set = std.ArrayList(AnyType).init(std.testing.allocator);
    defer command_set.deinit();

    try command_set.append(.{ .str = @constCast("DBSIZE") });

    var result = cmd_handler.process(&command_set);
    try std.testing.expectEqual(result.ok, .{ .int = 2 });
}
