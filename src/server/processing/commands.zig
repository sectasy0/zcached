const std = @import("std");

const ZType = @import("../../protocol/types.zig").ZType;

const Memory = @import("../storage/memory.zig");
const PersistanceHandler = @import("../storage/persistance.zig");

const TracingAllocator = @import("../tracing.zig").TracingAllocator;
const Config = @import("../config.zig");
const utils = @import("../utils.zig");
const Logger = @import("../logger.zig");

const CommandType = enum {
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
pub const Handler = struct {
    allocator: std.mem.Allocator,
    memory: *Memory,

    logger: *Logger,

    pub const Result = union(enum) { ok: ZType, err: anyerror };

    pub fn init(
        allocator: std.mem.Allocator,
        memory: *Memory,
        logger: *Logger,
    ) Handler {
        return Handler{
            .allocator = allocator,
            .memory = memory,
            .logger = logger,
        };
    }

    pub fn process(self: *Handler, command_set: *const std.ArrayList(ZType)) Result {
        if (command_set.capacity == 0) return .{ .err = error.UnknownCommand };

        // first element in command_set is command name and should be always str
        if (command_set.items[0] != .str) {
            return .{ .err = error.UnknownCommand };
        }

        const cmd_upper: []u8 = utils.to_uppercase(command_set.items[0].str);
        const command_type = std.meta.stringToEnum(CommandType, cmd_upper) orelse {
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
            .DBSIZE => return .{ .ok = .{ .int = self.memory.size() } },
            .SAVE => return self.save(),
            .MGET => return self.mget(command_set.items[1..command_set.items.len]),
            .MSET => return self.mset(command_set.items[1..command_set.items.len]),
            .KEYS => return self.zkeys(),
            .LASTSAVE => return .{ .ok = .{ .int = self.memory.last_save } },
        };
    }

    fn get(self: *Handler, key: ZType) Result {
        const value = self.memory.get(key.str) catch |err| {
            return .{ .err = err };
        };

        return .{ .ok = value };
    }

    fn set(self: *Handler, key: ZType, value: ZType) Result {
        // second element in command_set is key and should be always str
        if (key != .str) return .{ .err = error.KeyNotString };

        self.memory.put(key.str, value) catch |err| {
            return .{ .err = err };
        };

        return .{ .ok = .{ .sstr = @constCast("OK") } };
    }

    fn delete(self: *Handler, key: ZType) Result {
        const result = self.memory.delete(key.str);

        if (result) {
            return .{ .ok = .{ .sstr = @constCast("OK") } };
        } else {
            return .{ .err = error.NotFound };
        }
    }

    fn flush(self: *Handler) Result {
        self.memory.flush();
        return .{ .ok = .{ .sstr = @constCast("OK") } };
    }

    fn ping(self: *Handler) Result {
        _ = self;
        return .{ .ok = .{ .sstr = @constCast("PONG") } };
    }

    fn save(self: *Handler) Result {
        if (self.memory.size() == 0) return .{ .err = error.SaveFailure };

        const size = self.memory.save() catch |err| {
            self.logger.log(.Error, "# failed to save data: {?}", .{err});

            return .{ .err = error.SaveFailure };
        };

        self.logger.log(.Debug, "# saved {d} bytes", .{size});

        if (size > 0) return .{ .ok = .{ .sstr = @constCast("OK") } };

        return .{ .err = error.SaveFailure };
    }

    fn mget(self: *Handler, keys: []ZType) Result {
        var result = std.StringHashMap(ZType).init(self.allocator);

        for (keys) |key| {
            if (key != .str) return .{ .err = error.KeyNotString };

            const value: ZType = self.memory.get(key.str) catch .{ .null = void{} };

            result.put(key.str, value) catch |err| {
                return .{ .err = err };
            };
        }

        return .{ .ok = .{ .map = result } };
    }

    fn mset(self: *Handler, entries: []ZType) Result {
        if (entries.len == 0 or entries.len & 1 == 1) return .{ .err = error.InvalidArgs };

        for (entries, 0..) |entry, index| {
            // cause its an array so i have to assume every even element is a value.
            if (index & 1 == 1 or index + 1 == entries.len) continue;
            if (entry != .str) return .{ .err = error.KeyNotString };

            const value = entries[index + 1];

            self.memory.put(entry.str, value) catch |err| {
                return .{ .err = err };
            };
        }
        return .{ .ok = .{ .sstr = @constCast("OK") } };
    }

    fn zkeys(self: *Handler) Result {
        const result = self.memory.keys() catch |err| {
            return .{ .err = err };
        };
        return .{ .ok = .{ .array = result } };
    }

    // method to free data needs to be freeded, for example keys command
    // is creating std.ArrayList so it have to be freed after
    pub fn free(self: *Handler, command_set: *const std.ArrayList(ZType), result: *Result) void {
        _ = self;
        const cmd_upper: []u8 = utils.to_uppercase(command_set.items[0].str);
        const command_type = std.meta.stringToEnum(CommandType, cmd_upper) orelse return;

        switch (command_type) {
            .KEYS => result.ok.array.deinit(),
            else => return,
        }
    }
};
