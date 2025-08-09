const std = @import("std");

// Protocol types
const ZType = @import("../../protocol/types.zig").ZType;

// Storage
const Memory = @import("../storage/memory.zig");

// Tracing utilities
const TracingAllocator = @import("../tracing.zig").TracingAllocator;

// Configuration and utilities
const Config = @import("../config.zig");
const Logger = @import("../logger.zig");
const utils = @import("../utils.zig");

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
    SIZEOF,
    RENAME,
    ECHO,
    COPY,
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
        // first element in command_set is command name and should be always str
        if (command_set.capacity == 0 or command_set.items[0] != .str) {
            return .{ .err = error.UnknownCommand };
        }

        const command_type = utils.enum_type_from_str(CommandType, command_set.items[0].str) orelse {
            return .{ .err = error.UnknownCommand };
        };

        try switch (command_type) {
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
            .SIZEOF => {
                if (command_set.items.len < 2) return .{ .err = error.InvalidCommand };
                return self.sizeof(command_set.items[1]);
            },
            .RENAME => {
                if (command_set.items.len < 3) return .{ .err = error.InvalidCommand };
                return self.rename(command_set.items[1], command_set.items[2]);
            },
            .ECHO => {
                if (command_set.items.len < 2) return .{ .err = error.InvalidCommand };
                switch (command_set.items[1]) {
                    .str, .sstr => |text| return .{ .ok = .{ .str = text } },
                    else => return .{ .err = error.KeyNotString }, // Maybe rename it to FieldNotString or ValueNotString?
                }
            },
            .COPY => {
                if (command_set.items.len < 3) return .{ .err = error.InvalidCommand };
                return self.copy(command_set.items[1..command_set.items.len]);
            },
            .MGET => return self.mget(command_set.items[1..command_set.items.len]),
            .MSET => return self.mset(command_set.items[1..command_set.items.len]),
            .PING => return .{ .ok = .{ .sstr = @constCast("PONG") } },
            .DBSIZE => return .{ .ok = .{ .int = self.memory.size() } },
            .LASTSAVE => return .{ .ok = .{ .int = self.memory.last_save } },
            .SAVE => return self.save(),
            .KEYS => return self.zkeys(),
            .FLUSH => return self.flush(),
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

    fn sizeof(self: *Handler, key: ZType) Result {
        const value: ZType = self.memory.get(key.str) catch |err| {
            return .{ .err = err };
        };

        const value_size: usize = switch (value) {
            .str, .sstr => |str| str.len,
            .array => value.array.items.len,
            inline .map, .set, .uset => |v| v.count(),
            inline .int, .float, .bool => |x| @sizeOf(@TypeOf(x)),
            else => 0,
        };

        return .{ .ok = .{ .int = @intCast(value_size) } };
    }

    fn rename(self: *Handler, key: ZType, value: ZType) Result {
        if (key != .str or value != .str) return .{ .err = error.KeyNotString };

        self.memory.rename(key.str, value.str) catch |err| {
            return .{ .err = err };
        };

        return .{ .ok = .{ .sstr = @constCast("OK") } };
    }

    fn copy(self: *Handler, entries: []ZType) Result {
        const CopyArgs = enum { REPLACE };

        var replace: bool = false;
        if (entries[0] != .str or entries[1] != .str) return .{ .err = error.KeyNotString };

        if (entries.len > 2) {
            if (entries[2] != .str) return .{ .err = error.KeyNotString };

            // To check if entries[2] is "REPLACE" string.
            // If not, return error.BadRequest.
            _ = utils.enum_type_from_str(CopyArgs, entries[2].str) orelse return .{ .err = error.BadRequest };
            replace = true;
        }
        self.memory.copy(entries[0].str, entries[1].str, replace) catch |err| {
            return .{ .err = err };
        };
        return .{ .ok = .{ .str = @constCast("OK") } };
    }

    // method to free data needs to be freeded, for example keys command
    // is creating std.ArrayList so it have to be freed after
    pub fn free(self: *Handler, command_set: *const std.ArrayList(ZType), result: *Result) void {
        _ = self;
        const command_type = utils.enum_type_from_str(CommandType, command_set.items[0].str) orelse return;

        switch (command_type) {
            .KEYS => result.ok.array.deinit(),
            else => return,
        }
    }
};
