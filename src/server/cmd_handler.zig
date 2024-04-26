const std = @import("std");

const MemoryStorage = @import("storage.zig");
const ZType = @import("../protocol/types.zig").ZType;
const Config = @import("config.zig");
const utils = @import("utils.zig");
const Logger = @import("logger.zig");

const TracingAllocator = @import("tracing.zig").TracingAllocator;
const PersistanceHandler = @import("persistance.zig").PersistanceHandler;

const Commands = enum {
    PING,
    GET,
    SET,
    DELETE,
    FLUSH,
    MGET,
    MSET,
    DBSIZE,
    SAVE,
    KEYS,
    LASTSAVE,
};
pub const CMDHandler = struct {
    allocator: std.mem.Allocator,
    storage: *MemoryStorage,

    logger: *Logger,

    const HandlerResult = union(enum) { ok: ZType, err: anyerror };

    pub fn init(
        allocator: std.mem.Allocator,
        mstorage: *MemoryStorage,
        logger: *Logger,
    ) CMDHandler {
        return CMDHandler{
            .allocator = allocator,
            .storage = mstorage,
            .logger = logger,
        };
    }

    pub fn process(self: *CMDHandler, command_set: *const std.ArrayList(ZType)) HandlerResult {
        if (command_set.capacity == 0) return .{ .err = error.UnknownCommand };

        // first element in command_set is command name and should be always str
        if (command_set.items[0] != .str) {
            return .{ .err = error.UnknownCommand };
        }

        var cmd_upper: []u8 = utils.to_uppercase(command_set.items[0].str);
        const command_type = std.meta.stringToEnum(Commands, cmd_upper) orelse {
            return .{ .err = error.UnknownCommand };
        };
        try switch (command_type) {
            .PING => return self.ping(),
            .GET => {
                if (command_set.items.len < 2) return .{ .err = error.InvalidCommand };

                return self.get(command_set.items[1]);
            },
            .SET => {
                if (command_set.items.len < 3) return .{ .err = error.InvalidCommand };

                return self.set(command_set.items[1], command_set.items[2]);
            },
            .DELETE => {
                if (command_set.items.len < 2) return .{ .err = error.InvalidCommand };

                return self.delete(command_set.items[1]);
            },
            .FLUSH => return self.flush(),
            .DBSIZE => return .{ .ok = .{ .int = self.storage.size() } },
            .SAVE => return self.save(),
            .MGET => return self.mget(command_set.items[1..command_set.items.len]),
            .MSET => return self.mset(command_set.items[1..command_set.items.len]),
            .KEYS => return self.zkeys(),
            .LASTSAVE => return .{ .ok = .{ .int = self.storage.last_save } },
        };
    }

    fn get(self: *CMDHandler, key: ZType) HandlerResult {
        const value = self.storage.get(key.str) catch |err| {
            return .{ .err = err };
        };

        return .{ .ok = value };
    }

    fn set(self: *CMDHandler, key: ZType, value: ZType) HandlerResult {
        // second element in command_set is key and should be always str
        if (key != .str) return .{ .err = error.KeyNotString };

        self.storage.put(key.str, value) catch |err| {
            return .{ .err = err };
        };

        return .{ .ok = .{ .sstr = @constCast("OK") } };
    }

    fn delete(self: *CMDHandler, key: ZType) HandlerResult {
        const result = self.storage.delete(key.str);

        if (result) {
            return .{ .ok = .{ .sstr = @constCast("OK") } };
        } else {
            return .{ .err = error.NotFound };
        }
    }

    fn flush(self: *CMDHandler) HandlerResult {
        self.storage.flush();
        return .{ .ok = .{ .sstr = @constCast("OK") } };
    }

    fn ping(self: *CMDHandler) HandlerResult {
        _ = self;
        return .{ .ok = .{ .sstr = @constCast("PONG") } };
    }

    fn save(self: *CMDHandler) HandlerResult {
        if (self.storage.size() == 0) return .{ .err = error.SaveFailure };

        const size = self.storage.save() catch |err| {
            self.logger.log(.Error, "# failed to save data: {?}", .{err});

            return .{ .err = error.SaveFailure };
        };

        self.logger.log(.Debug, "# saved {d} bytes", .{size});

        if (size > 0) return .{ .ok = .{ .sstr = @constCast("OK") } };

        return .{ .err = error.SaveFailure };
    }

    fn mget(self: *CMDHandler, keys: []ZType) HandlerResult {
        var result = std.StringHashMap(ZType).init(self.allocator);

        for (keys) |key| {
            if (key != .str) return .{ .err = error.KeyNotString };

            const value: ZType = self.storage.get(key.str) catch .{ .null = void{} };

            result.put(key.str, value) catch |err| {
                return .{ .err = err };
            };
        }

        return .{ .ok = .{ .map = result } };
    }

    fn mset(self: *CMDHandler, entries: []ZType) HandlerResult {
        if (entries.len == 0 or entries.len & 1 == 1) return .{ .err = error.InvalidArgs };

        for (entries, 0..) |entry, index| {
            // cause its an array so i have to assume every even element is a value.
            if (index & 1 == 1 or index + 1 == entries.len) continue;
            if (entry != .str) return .{ .err = error.KeyNotString };

            var value = entries[index + 1];

            self.storage.put(entry.str, value) catch |err| {
                return .{ .err = err };
            };
        }
        return .{ .ok = .{ .sstr = @constCast("OK") } };
    }

    fn zkeys(self: *CMDHandler) HandlerResult {
        var result = self.storage.keys() catch |err| {
            return .{ .err = err };
        };
        return .{ .ok = .{ .array = result } };
    }

    // method to free data needs to be freeded, for example keys command
    // is creating std.ArrayList so it have to be freed after
    pub fn free(self: *CMDHandler, command_set: *const std.ArrayList(ZType), result: *HandlerResult) void {
        _ = self;
        var cmd_upper: []u8 = utils.to_uppercase(command_set.items[0].str);
        const command_type = std.meta.stringToEnum(Commands, cmd_upper) orelse return;

        switch (command_type) {
            .KEYS => result.ok.array.deinit(),
            else => return,
        }
    }
};
