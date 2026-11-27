//! Dispatches decoded protocol commands to storage and persistence operations.
//! Returned values may own allocator-backed data; callers release them with `Handler.free`.

const std = @import("std");

// Protocol types
const types = @import("../../protocol/types.zig");
const ZType = types.ZType;

// Storage
const Memory = @import("../storage/memory.zig");

// Processing / application logic
const Context = @import("../context.zig");

// Tracing utilities
const TracingAllocator = @import("../tracing.zig").TracingAllocator;

// Configuration and utilities
const Config = @import("../config.zig");
const Logger = @import("../logger.zig");
const utils = @import("../utils.zig");

/// Commands recognized by the dispatcher; names are matched case-insensitively.
const CommandType = enum {
    /// Return the server's liveness response.
    PING,
    /// Return a copy of the value stored at a key.
    GET,
    /// Store a value at a key.
    SET,
    GSET,
    /// Set the expiration time for a key.
    /// Returns 1 if the timeout was set, 0 if the key does not exist.
    EXPIRE,
    TTL,
    PERSIST,
    PEXPIREAT, // Internal journal record.
    /// Remove a key from storage.
    DELETE,
    /// Remove all stored entries.
    FLUSH,
    /// Return values for multiple keys, using null for absent keys.
    MGET,
    /// Store multiple key/value pairs.
    MSET,
    /// Store multiple key/value pairs only when all keys are absent.
    MSETNX,
    /// Increment an integer-compatible value.
    INCR,
    /// Decrement an integer-compatible value.
    DECR,
    /// Append bytes to a string value.
    APPEND,
    /// Return the number of stored keys.
    DBSIZE,
    /// Persist the current in-memory state.
    SAVE,
    /// Queue persistence of the current in-memory state.
    ASAVE,
    /// Return a snapshot of all keys.
    KEYS,
    /// Return the timestamp of the last persistence save.
    LASTSAVE,
    /// Return the encoded size of a stored value.
    SIZEOF,
    /// Move a value from one key to another.
    RENAME,
    /// Return the supplied string unchanged.
    ECHO,
    /// Copy a value to another key, optionally replacing its contents.
    COPY,
    /// Return server metadata in Redis-style text sections.
    INFO,
    /// Describe supported commands or return command counts.
    COMMAND,
    /// Return basic client connection metadata.
    CLIENT,
};

/// Executes commands against the shared application context.
pub const Handler = struct {
    /// Allocator used for result copies and temporary collections; `free` must use it too.
    allocator: std.mem.Allocator,

    /// Storage, persistence, logging, and configuration dependencies.
    context: Context,
    /// Command currently being processed, borrowed only until `process` returns.
    pending_command: ?[]const ZType = null,
    replaying: bool = false,

    /// Either a successful protocol value or the error that prevented execution.
    pub const Result = union(enum) {
        /// Successful result; some aggregate values own memory allocated by `allocator`.
        ok: ZType,
        /// Failure from validation, storage, serialization, or persistence.
        err: anyerror,
    };

    /// Creates a handler that borrows the supplied context and uses `allocator` for results.
    pub fn init(allocator: std.mem.Allocator, context: Context) Handler {
        return Handler{ .allocator = allocator, .context = context };
    }

    /// Validates and dispatches a command array, borrowing it temporarily for AOF mutation logging.
    /// The input is borrowed; returned owned results must be released with `free`.
    pub fn process(self: *Handler, command_set: *const std.array_list.Managed(ZType)) Result {
        self.pending_command = command_set.items;
        defer self.pending_command = null;

        // first element in command_set is command name and should be always str
        if (command_set.items.len == 0 or command_set.items[0] != .str) {
            return .{ .err = error.UnknownCommand };
        }

        const command_type = utils.enumTypeFromStr(CommandType, command_set.items[0].str) orelse {
            return .{ .err = error.UnknownCommand };
        };

        try switch (command_type) {
            .GET => {
                if (command_set.items.len != 2) return .{ .err = error.InvalidCommand };
                return self.get(command_set.items[1]);
            },
            .SET => {
                return self.set(command_set.items[1..]);
            },
            .GSET => {
                if (command_set.items.len != 3) return .{ .err = error.InvalidCommand };
                return self.getOrSet(command_set.items[1], command_set.items[2]);
            },
            .EXPIRE, .PEXPIREAT => {
                if (command_type == .PEXPIREAT and !self.replaying) return .{ .err = error.UnknownCommand };
                if (command_set.items.len != 3) return .{ .err = error.InvalidCommand };
                return self.expire(command_set.items[1], command_set.items[2], command_type == .PEXPIREAT);
            },
            .TTL, .PERSIST => {
                if (command_set.items.len != 2) return .{ .err = error.InvalidCommand };
                const key = command_set.items[1];
                if (key != .str) return .{ .err = error.KeyNotString };
                const memory = self.context.resources.memory;
                if (command_type == .TTL) return .{ .ok = .{ .int = memory.ttl(key.str) } };
                if (!memory.persist(key.str)) return .{ .ok = .{ .int = 0 } };
                self.appendMutation() catch |err| return .{ .err = err };
                return .{ .ok = .{ .int = 1 } };
            },
            .DELETE => {
                if (command_set.items.len != 2) return .{ .err = error.InvalidCommand };
                return self.delete(command_set.items[1]);
            },
            .SIZEOF => {
                if (command_set.items.len != 2) return .{ .err = error.InvalidCommand };
                return self.sizeof(command_set.items[1]);
            },
            .RENAME => {
                if (command_set.items.len != 3) return .{ .err = error.InvalidCommand };
                return self.rename(command_set.items[1], command_set.items[2]);
            },
            .ECHO => {
                if (command_set.items.len != 2) return .{ .err = error.InvalidCommand };
                switch (command_set.items[1]) {
                    .str => |text| return .{ .ok = .{ .str = text } },
                    .sstr => |text| return .{ .ok = .{ .sstr = text } },
                    else => return .{ .err = error.KeyNotString }, // Maybe rename it to FieldNotString or ValueNotString?
                }
            },
            .COPY => {
                if (command_set.items.len < 3) return .{ .err = error.InvalidCommand };
                if (command_set.items.len > 4) return .{ .err = error.InvalidCommand };
                return self.copy(command_set.items[1..command_set.items.len]);
            },
            .INFO => {
                if (command_set.items.len > 1) return .{ .err = error.InvalidCommand };
                return self.info();
            },
            .COMMAND => return self.commandList(command_set.items[1..]),
            .CLIENT => return self.clientInfo(command_set.items[1..]),
            .MGET => {
                if (command_set.items.len < 2) return .{ .err = error.InvalidArgs };
                return self.mget(command_set.items[1..command_set.items.len]);
            },
            .MSET => return self.mset(command_set.items[1..command_set.items.len]),
            .MSETNX => return self.msetnx(command_set.items[1..]),
            .INCR => {
                if (command_set.items.len != 2) return .{ .err = error.InvalidCommand };
                return self.increment(command_set.items[1], 1);
            },
            .DECR => {
                if (command_set.items.len != 2) return .{ .err = error.InvalidCommand };
                return self.increment(command_set.items[1], -1);
            },
            .APPEND => {
                if (command_set.items.len != 3) return .{ .err = error.InvalidCommand };
                return self.append(command_set.items[1], command_set.items[2]);
            },
            .PING => {
                if (command_set.items.len != 1) return .{ .err = error.InvalidCommand };
                return .{ .ok = .{ .sstr = "PONG" } };
            },
            .DBSIZE => {
                if (command_set.items.len != 1) return .{ .err = error.InvalidCommand };
                return .{ .ok = .{ .int = self.context.resources.memory.size() } };
            },
            .LASTSAVE => {
                if (command_set.items.len != 1) return .{ .err = error.InvalidCommand };
                return .{ .ok = .{ .int = self.context.resources.memory.last_save.load(.monotonic) } };
            },
            .SAVE => {
                if (command_set.items.len != 1) return .{ .err = error.InvalidCommand };
                return self.save();
            },
            .ASAVE => {
                if (command_set.items.len != 1) return .{ .err = error.InvalidCommand };
                return self.asave();
            },
            .KEYS => {
                if (command_set.items.len != 1) return .{ .err = error.InvalidCommand };
                return self.zkeys();
            },
            .FLUSH => {
                if (command_set.items.len != 1) return .{ .err = error.InvalidCommand };
                return self.flush();
            },
        };
    }

    /// Returns an owned copy of a string-keyed value, or a key/type/storage error.
    fn get(self: *Handler, key: ZType) Result {
        if (key != .str) return .{ .err = error.KeyNotString };
        const value = self.context.resources.memory.getCopy(key.str, self.allocator) catch |err| {
            return .{ .err = err };
        };

        return .{ .ok = value };
    }

    /// Stores the value for a string key and records the successful mutation in the AOF.
    fn set(self: *Handler, args: []const ZType) Result {
        if (args.len != 2 and args.len != 4) return .{ .err = error.InvalidCommand };
        const key = args[0];
        if (key != .str) return .{ .err = error.KeyNotString };
        const value = args[1];
        const memory = self.context.resources.memory;
        if (args.len == 2) {
            memory.put(key.str, value) catch |err| return .{ .err = err };
            self.appendMutation() catch |err| return .{ .err = err };
        } else {
            if (args[2] != .str) return .{ .err = error.InvalidCommand };
            const duration = parseExpiry(args[3]) catch |err| return .{ .err = err };
            if (duration <= 0) return .{ .err = error.InvalidExpiry };
            const option = args[2].str;
            const deadline = if (self.replaying and std.ascii.eqlIgnoreCase(option, "PXAT"))
                duration
            else if (std.ascii.eqlIgnoreCase(option, "EX"))
                relativeDeadline(duration, 1000) catch |err| return .{ .err = err }
            else if (std.ascii.eqlIgnoreCase(option, "PX"))
                relativeDeadline(duration, 1) catch |err| return .{ .err = err }
            else
                return .{ .err = error.InvalidCommand };
            memory.putExpiring(key.str, value, deadline) catch |err| return .{ .err = err };
            self.appendCommand(&.{ .{ .str = "SET" }, key, value, .{ .str = "PXAT" }, .{ .int = deadline } }) catch |err|
                return .{ .err = err };
        }
        return .{ .ok = .{ .sstr = "OK" } };
    }

    fn getOrSet(self: *Handler, key: ZType, fallback: ZType) Result {
        if (key != .str) return .{ .err = error.KeyNotString };
        var result = self.context.resources.memory.getOrSet(key.str, fallback, self.allocator) catch |err|
            return .{ .err = err };
        if (result.inserted) {
            // Replay must apply the write even if an expired historical value still exists.
            self.appendCommand(&.{ .{ .str = "SET" }, key, fallback }) catch |err| {
                types.ztype_free(&result.value, self.allocator);
                return .{ .err = err };
            };
        }
        return .{ .ok = result.value };
    }

    fn parseExpiry(value: ZType) error{InvalidExpiry}!i64 {
        return switch (value) {
            .int => value.int,
            .str, .sstr => |text| std.fmt.parseInt(i64, text, 10) catch error.InvalidExpiry,
            else => error.InvalidExpiry,
        };
    }

    fn relativeDeadline(duration: i64, scale: i64) error{InvalidExpiry}!i64 {
        const milliseconds = std.math.mul(i64, duration, scale) catch return error.InvalidExpiry;
        return std.math.add(i64, Memory.unixMillis(), milliseconds) catch error.InvalidExpiry;
    }

    fn expire(self: *Handler, key: ZType, value: ZType, absolute: bool) Result {
        if (key != .str) return .{ .err = error.KeyNotString };
        const expiry = parseExpiry(value) catch |err| return .{ .err = err };
        const deadline = if (expiry <= 0 or absolute)
            @max(expiry, 0)
        else
            relativeDeadline(expiry, 1000) catch |err| return .{ .err = err };
        if (!self.context.resources.memory.expireAt(key.str, deadline)) return .{ .ok = .{ .int = 0 } };
        self.appendCommand(&.{ .{ .str = "PEXPIREAT" }, key, .{ .int = deadline } }) catch |err|
            return .{ .err = err };
        return .{ .ok = .{ .int = 1 } };
    }

    /// Deletes an existing key and records the mutation; returns `NotFound` if absent.
    fn delete(self: *Handler, key: ZType) Result {
        if (key != .str) return .{ .err = error.KeyNotString };
        const result = self.context.resources.memory.delete(key.str);

        if (result) {
            self.appendMutation() catch |err| return .{ .err = err };
            return .{ .ok = .{ .sstr = "OK" } };
        } else {
            return .{ .err = error.NotFound };
        }
    }

    /// Clears storage and records the flush operation for replay.
    fn flush(self: *Handler) Result {
        self.context.resources.memory.flush();
        self.appendMutation() catch |err| return .{ .err = err };
        return .{ .ok = .{ .sstr = "OK" } };
    }

    /// Saves non-empty in-memory data through the configured persistence handler.
    fn save(self: *Handler) Result {
        if (self.context.resources.memory.size() == 0) return .{ .err = error.SaveFailure };

        const size = self.context.resources.memory.save() catch |err| {
            self.context.resources.logger.err("# failed to save data: {any}", .{err});

            return .{ .err = error.SaveFailure };
        };

        self.context.resources.logger.debug("# saved {d} bytes", .{size});

        if (size > 0) return .{ .ok = .{ .sstr = "OK" } };

        return .{ .err = error.SaveFailure };
    }

    /// Queues a snapshot without waiting for encoding or filesystem I/O.
    fn asave(self: *Handler) Result {
        if (self.context.resources.memory.size() == 0) return .{ .err = error.SaveFailure };
        self.context.resources.memory.saveAsync(self.context.resources.agent) catch |err|
            return .{ .err = err };
        return .{ .ok = .{ .sstr = "OK" } };
    }

    /// Builds an owned map of requested values, substituting null for missing keys.
    /// On failure, frees all values accumulated before returning the error.
    fn mget(self: *Handler, keys: []ZType) Result {
        for (keys) |key| {
            if (key != .str) return .{ .err = error.KeyNotString };
        }
        var result = std.StringHashMap(ZType).init(self.allocator);

        for (keys) |key| {
            var value: ZType = self.context.resources.memory.getCopy(key.str, self.allocator) catch |err| switch (err) {
                error.NotFound => .{ .null = {} },
                else => {
                    self.freeMapValues(&result);
                    return .{ .err = err };
                },
            };
            const entry = result.getOrPut(key.str) catch |err| {
                types.ztype_free(&value, self.allocator);
                self.freeMapValues(&result);
                return .{ .err = err };
            };
            if (entry.found_existing) types.ztype_free(entry.value_ptr, self.allocator);
            entry.value_ptr.* = value;
        }

        return .{ .ok = .{ .map = result } };
    }

    /// Stores alternating key/value arguments and appends each successful pair as a SET.
    /// Requires at least one pair and an even number of entries.
    fn mset(self: *Handler, entries: []ZType) Result {
        if (entries.len == 0 or entries.len & 1 == 1) return .{ .err = error.InvalidArgs };

        for (entries, 0..) |entry, index| {
            // cause its an array so i have to assume every even element is a value.
            if (index & 1 == 1 or index + 1 == entries.len) continue;
            if (entry != .str) return .{ .err = error.KeyNotString };

            const value = entries[index + 1];

            self.context.resources.memory.put(entry.str, value) catch |err| {
                return .{ .err = err };
            };

            const set_command = [_]ZType{ .{ .str = "SET" }, entry, value };
            self.appendCommand(&set_command) catch |err| return .{ .err = err };
        }
        return .{ .ok = .{ .sstr = "OK" } };
    }

    /// Atomically stores all pairs only when every requested key is absent.
    fn msetnx(self: *Handler, entries: []ZType) Result {
        if (entries.len == 0 or entries.len & 1 == 1) return .{ .err = error.InvalidArgs };
        var index: usize = 0;
        while (index < entries.len) : (index += 2) {
            if (entries[index] != .str) return .{ .err = error.KeyNotString };
        }
        const inserted = self.context.resources.memory.putAllIfAbsent(entries) catch |err|
            return .{ .err = err };
        if (!inserted) return .{ .ok = .{ .int = 0 } };
        self.appendMutation() catch |err| return .{ .err = err };
        return .{ .ok = .{ .int = 1 } };
    }

    fn increment(self: *Handler, key: ZType, delta: i64) Result {
        if (key != .str) return .{ .err = error.KeyNotString };
        const result = self.context.resources.memory.increment(key.str, delta) catch |err|
            return .{ .err = err };
        self.appendMutation() catch |err| return .{ .err = err };
        return .{ .ok = .{ .int = result } };
    }

    fn append(self: *Handler, key: ZType, suffix: ZType) Result {
        if (key != .str) return .{ .err = error.KeyNotString };
        const suffix_bytes: []const u8 = switch (suffix) {
            .str, .sstr => |value| value,
            else => return .{ .err = error.InvalidType },
        };
        const length = self.context.resources.memory.append(key.str, suffix_bytes) catch |err|
            return .{ .err = err };
        self.appendMutation() catch |err| return .{ .err = err };
        return .{ .ok = .{ .int = @intCast(length) } };
    }

    /// Returns an owned array containing copies of all storage keys.
    fn zkeys(self: *Handler) Result {
        const result = self.context.resources.memory.keysCopy(self.allocator) catch |err| {
            return .{ .err = err };
        };
        return .{ .ok = .{ .array = result } };
    }

    /// Returns the encoded size of the value at a string key.
    fn sizeof(self: *Handler, key: ZType) Result {
        if (key != .str) return .{ .err = error.KeyNotString };
        const value_size = self.context.resources.memory.valueSize(key.str) catch |err| {
            return .{ .err = err };
        };

        return .{ .ok = .{ .int = @intCast(value_size) } };
    }

    /// Renames a string key and records the mutation; both arguments must be strings.
    fn rename(self: *Handler, key: ZType, value: ZType) Result {
        if (key != .str or value != .str) return .{ .err = error.KeyNotString };

        self.context.resources.memory.rename(key.str, value.str) catch |err| {
            return .{ .err = err };
        };

        self.appendMutation() catch |err| return .{ .err = err };
        return .{ .ok = .{ .sstr = "OK" } };
    }

    /// Copies a key to a destination, accepting only the optional `REPLACE` modifier.
    fn copy(self: *Handler, entries: []ZType) Result {
        const CopyArgs = enum { REPLACE };

        var replace: bool = false;
        if (entries[0] != .str or entries[1] != .str) return .{ .err = error.KeyNotString };

        if (entries.len > 2) {
            if (entries[2] != .str) return .{ .err = error.KeyNotString };

            // To check if entries[2] is "REPLACE" string.
            // If not, return error.BadRequest.
            _ = utils.enumTypeFromStr(CopyArgs, entries[2].str) orelse return .{ .err = error.BadRequest };
            replace = true;
        }
        self.context.resources.memory.copy(entries[0].str, entries[1].str, replace) catch |err| {
            return .{ .err = err };
        };
        // Replay may still have the destination's historical, now-expired value.
        self.appendCommand(&.{ .{ .str = "COPY" }, entries[0], entries[1], .{ .str = "REPLACE" } }) catch |err|
            return .{ .err = err };
        return .{ .ok = .{ .str = "OK" } };
    }

    /// Returns server identity and key-space/resource metadata.
    fn info(self: *Handler) Result {
        const text = std.fmt.allocPrint(
            self.allocator,
            "# Server\r\nzcached_version:0.0.1\r\nworkers:{d}\r\nmax_clients:{d}\r\ntls_enabled:{s}\r\n\r\n# Connections\r\nconnections_accepted_total:{d}\r\nconnections_active:{d}\r\nconnections_closed_total:{d}\r\nread_timeouts_total:{d}\r\nauth_timeouts_total:{d}\r\nrequest_limit_rejections_total:{d}\r\n\r\n# Traffic\r\ncommands_total:{d}\r\ncommand_errors_total:{d}\r\nauth_failures_total:{d}\r\nauthorization_denials_total:{d}\r\nmalformed_requests_total:{d}\r\nmemory_limit_rejections_total:{d}\r\nresponse_limit_rejections_total:{d}\r\nrequest_bytes_total:{d}\r\nresponse_bytes_total:{d}\r\nresponse_batches_total:{d}\r\nwrite_errors_total:{d}\r\n\r\n# Persistence\r\naof_enabled:{s}\r\nlast_save_timestamp:{d}\r\nsave_in_progress:{s}\r\n\r\n# Keyspace\r\ndb_keys:{d}\r\nused_memory:{d}\r\nmemory_limit:{d}\r\n",
            .{
                self.context.config.workers,
                self.context.config.max_clients,
                if (self.context.config.tls.enabled) "1" else "0",
                self.context.resources.metrics.connections_accepted.load(.monotonic),
                self.context.resources.metrics.connections_active.load(.monotonic),
                self.context.resources.metrics.connections_closed.load(.monotonic),
                self.context.resources.metrics.read_timeouts_total.load(.monotonic),
                self.context.resources.metrics.auth_timeouts_total.load(.monotonic),
                self.context.resources.metrics.request_limit_rejections_total.load(.monotonic),
                self.context.resources.metrics.commands_total.load(.monotonic),
                self.context.resources.metrics.command_errors_total.load(.monotonic),
                self.context.resources.metrics.auth_failures_total.load(.monotonic),
                self.context.resources.metrics.authorization_denials_total.load(.monotonic),
                self.context.resources.metrics.malformed_requests_total.load(.monotonic),
                self.context.resources.metrics.memory_limit_rejections_total.load(.monotonic),
                self.context.resources.metrics.response_limit_rejections_total.load(.monotonic),
                self.context.resources.metrics.request_bytes_total.load(.monotonic),
                self.context.resources.metrics.response_bytes_total.load(.monotonic),
                self.context.resources.metrics.response_batches_total.load(.monotonic),
                self.context.resources.metrics.write_errors_total.load(.monotonic),
                if (self.context.config.aof.flush_strategy == .no) "0" else "1",
                self.context.resources.memory.last_save.load(.monotonic),
                if (self.context.resources.memory.isSaveInProgress()) "1" else "0",
                self.context.resources.memory.size(),
                self.context.resources.memory.memoryUsed(),
                self.context.resources.memory.fabric.limit,
            },
        ) catch |err| return .{ .err = err };
        return .{ .ok = .{ .str = text } };
    }

    /// Lists public commands or reports the command count.
    fn commandList(self: *Handler, args: []ZType) Result {
        const names = [_][]const u8{
            "PING",    "AUTH",   "GET",    "SET",  "GSET",  "EXPIRE",  "TTL",
            "PERSIST", "DELETE", "FLUSH",  "MGET", "MSET",  "MSETNX",  "INCR",
            "DECR",    "APPEND", "DBSIZE", "SAVE", "ASAVE", "KEYS",    "LASTSAVE",
            "SIZEOF",  "RENAME", "ECHO",   "COPY", "INFO",  "COMMAND", "CLIENT",
        };
        if (args.len == 1 and args[0] == .str and std.ascii.eqlIgnoreCase(args[0].str, "COUNT")) {
            return .{ .ok = .{ .int = @intCast(names.len) } };
        }
        if (args.len != 0) return .{ .err = error.InvalidCommand };

        var result = ZType.Array.initCapacity(self.allocator, names.len) catch |err|
            return .{ .err = err };
        errdefer {
            var owned: ZType = .{ .array = result };
            types.ztype_free(&owned, self.allocator);
        }
        for (names) |name| {
            result.appendAssumeCapacity(.{ .str = self.allocator.dupe(u8, name) catch |err| return .{ .err = err } });
        }
        return .{ .ok = .{ .array = result } };
    }

    /// Returns basic connection metadata for the supported CLIENT subcommands.
    fn clientInfo(self: *Handler, args: []ZType) Result {
        _ = self;
        if (args.len == 1 and args[0] == .str) {
            if (std.ascii.eqlIgnoreCase(args[0].str, "LIST")) {
                return .{ .ok = .{ .str = "id=0 addr=unknown name=\r\n" } };
            }
            if (std.ascii.eqlIgnoreCase(args[0].str, "ID")) {
                return .{ .ok = .{ .int = 0 } };
            }
        }
        return .{ .err = error.InvalidCommand };
    }

    /// Appends the currently processed command to AOF, if one is configured.
    fn appendMutation(self: *Handler) !void {
        const command = self.pending_command orelse return error.InvalidCommand;
        try self.appendCommand(command);
    }

    /// Serializes and appends a command to AOF; a disabled or absent AOF is a no-op.
    fn appendCommand(self: *Handler, command: []const ZType) !void {
        const aof = self.context.resources.aof orelse return;
        try aof.appendCommand(command);
    }

    /// Releases allocator-owned data in a successful result according to its command kind.
    /// Does not free the borrowed command arguments; call only for successful results.
    pub fn free(self: *Handler, command_set: *const std.array_list.Managed(ZType), result: *Result) void {
        const command_type = utils.enumTypeFromStr(CommandType, command_set.items[0].str) orelse return;

        switch (command_type) {
            .GET, .GSET, .KEYS, .INFO, .COMMAND => types.ztype_free(&result.ok, self.allocator),
            .MGET => self.freeMapValues(&result.ok.map),
            else => return,
        }
    }

    /// Frees every owned map value and then the map's backing storage.
    fn freeMapValues(self: *Handler, map: *ZType.Map) void {
        var iterator = map.valueIterator();
        while (iterator.next()) |value| types.ztype_free(value, self.allocator);
        map.deinit();
    }
};
