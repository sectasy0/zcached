//! Token authentication and command/key authorization backed by an external ZON file.

const std = @import("std");
const fs = @import("fs");
const runtime_io = @import("runtime_io");
const Config = @import("config.zig");
const ZType = @import("../protocol/types.zig").ZType;

pub const CommandGroup = enum {
    read_only,
    basic,
    diagnostic,
    maintenance,
    all,
};

const Permissions = struct {
    groups: []const CommandGroup = &.{},
    allow: []const []const u8 = &.{},
    deny: []const []const u8 = &.{},
    read: []const []const u8 = &.{},
    write: []const []const u8 = &.{},
    delete: []const []const u8 = &.{},
    admin: bool = false,
};

const PrincipalConfig = struct {
    name: []const u8,
    token_sha256: []const u8,
    permissions: Permissions,
};

pub const Principal = struct {
    name: []const u8,
    token_hash: [32]u8,
    permissions: Permissions,
};

const File = struct {
    principals: []const PrincipalConfig = &.{},
};

const Store = @This();

pub const Session = struct {
    principal: ?usize = null,
    attempts: u16 = 0,
    window_started: i64 = 0,
    blocked_until: i64 = 0,

    pub fn isAuthenticated(self: *const Session) bool {
        return self.principal != null;
    }
};

enabled: bool,
arena: std.heap.ArenaAllocator,
principals: []Principal = &.{},

pub fn init(allocator: std.mem.Allocator, config: Config.AuthConfig) !Store {
    var store = Store{
        .enabled = config.enabled,
        .arena = .init(allocator),
    };
    errdefer store.deinit();
    if (!config.enabled) return store;

    const path = config.path orelse return error.MissingAuthPath;
    const file = try fs.cwd().openFile(path, .{ .mode = .read_only });
    defer file.close();
    const bytes = try file.readToEndAllocOptions(allocator, 1024 * 1024, 0, .@"1", 0);
    defer allocator.free(bytes);

    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const arena = store.arena.allocator();
    const parsed = std.zon.parse.fromSlice(File, .{
        .gpa = allocator,
        .arena = arena,
        .source = bytes,
        .diagnostics = &diagnostics,
    }) catch |err| {
        if (err == error.ParseZon) std.debug.print("{f}", .{diagnostics.fmt("auth file")});
        return err;
    };
    if (parsed.principals.len == 0) return error.InvalidAuthFile;
    store.principals = try arena.alloc(Principal, parsed.principals.len);
    for (parsed.principals, 0..) |entry, index| {
        if (entry.name.len == 0 or entry.token_sha256.len != 64)
            return error.InvalidPrincipal;
        var token_hash: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&token_hash, entry.token_sha256) catch return error.InvalidPrincipal;
        validatePermissions(entry.permissions) catch return error.InvalidPrincipal;
        for (store.principals[0..index]) |previous| {
            if (std.mem.eql(u8, previous.name, entry.name) or
                std.crypto.timing_safe.eql([32]u8, previous.token_hash, token_hash))
                return error.InvalidPrincipal;
        }
        store.principals[index] = .{
            .name = entry.name,
            .token_hash = token_hash,
            .permissions = entry.permissions,
        };
    }
    return store;
}

pub fn deinit(self: *Store) void {
    self.arena.deinit();
}

pub fn authenticate(
    self: *const Store,
    session: *Session,
    token: []const u8,
    policy: Config.AuthConfig,
) error{ InvalidCredentials, AuthRateLimited }!void {
    const now = std.Io.Clock.awake.now(runtime_io.get()).toMilliseconds();
    if (session.blocked_until > now) return error.AuthRateLimited;
    if (self.findPrincipal(token)) |principal_index| {
        session.principal = principal_index;
        session.attempts = 0;
        session.window_started = now;
        session.blocked_until = 0;
        return;
    }

    if (session.window_started == 0 or now - session.window_started > policy.rate_window_ms) {
        session.window_started = now;
        session.attempts = 0;
    }
    if (policy.max_attempts != 0) {
        if (session.attempts < policy.max_attempts) session.attempts += 1;
        if (session.attempts >= policy.max_attempts)
            session.blocked_until = now + @as(i64, policy.rate_block_ms);
    }
    return error.InvalidCredentials;
}

fn findPrincipal(self: *const Store, token: []const u8) ?usize {
    if (!self.enabled) return null;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
    var matched: ?usize = null;
    for (self.principals, 0..) |entry, index| {
        if (std.crypto.timing_safe.eql([32]u8, digest, entry.token_hash)) matched = index;
    }
    return matched;
}

fn validatePermissions(permissions: Permissions) !void {
    for (permissions.allow) |value| if (value.len == 0) return error.InvalidPermissions;
    for (permissions.deny) |value| if (value.len == 0) return error.InvalidPermissions;
    for (permissions.read) |value| if (value.len == 0) return error.InvalidPermissions;
    for (permissions.write) |value| if (value.len == 0) return error.InvalidPermissions;
    for (permissions.delete) |value| if (value.len == 0) return error.InvalidPermissions;
}

pub fn principal(self: *const Store, index: usize) ?*const Principal {
    return if (index < self.principals.len) &self.principals[index] else null;
}

pub fn authorize(self: *const Store, principal_index: usize, command_set: []const ZType) bool {
    const selected = self.principal(principal_index) orelse return false;
    if (command_set.len == 0 or command_set[0] != .str) return false;
    const command = command_set[0].str;
    if (commandDenied(selected.permissions, command)) return false;
    if (!commandAllowed(selected.permissions, command)) return false;
    if (std.ascii.eqlIgnoreCase(command, "FLUSH") and !selected.permissions.admin) return false;
    return scopesAllowed(selected.permissions, command, command_set);
}

fn commandDenied(permissions: Permissions, command: []const u8) bool {
    for (permissions.deny) |name| if (std.ascii.eqlIgnoreCase(name, command)) return true;
    return false;
}

fn commandAllowed(permissions: Permissions, command: []const u8) bool {
    for (permissions.allow) |name|
        if (std.mem.eql(u8, name, "*") or std.ascii.eqlIgnoreCase(name, command)) return true;
    for (permissions.groups) |group| {
        if (group == .all or groupContains(group, command)) return true;
    }
    return false;
}

fn groupContains(group: CommandGroup, command: []const u8) bool {
    const names: []const []const u8 = switch (group) {
        .read_only => &.{ "PING", "GET", "MGET", "TTL", "SIZEOF", "DBSIZE" },
        .basic => &.{ "PING", "GET", "SET", "GSET", "EXPIRE", "TTL", "PERSIST", "DELETE", "MGET", "MSET", "MSETNX", "INCR", "DECR", "APPEND", "SIZEOF", "RENAME", "ECHO", "COPY" },
        .diagnostic => &.{ "PING", "INFO", "COMMAND", "CLIENT", "LASTSAVE", "DBSIZE" },
        .maintenance => &.{ "SAVE", "ASAVE", "FLUSH" },
        .all => &.{},
    };
    for (names) |name| if (std.ascii.eqlIgnoreCase(name, command)) return true;
    return false;
}

fn scopesAllowed(permissions: Permissions, command: []const u8, args: []const ZType) bool {
    if (std.ascii.eqlIgnoreCase(command, "GET") or
        std.ascii.eqlIgnoreCase(command, "TTL") or
        std.ascii.eqlIgnoreCase(command, "SIZEOF"))
        return keyAllowed(permissions.read, argumentKey(args, 1));
    if (std.ascii.eqlIgnoreCase(command, "MGET")) {
        for (args[1..]) |key| if (!keyAllowed(permissions.read, key)) return false;
        return true;
    }
    if (std.ascii.eqlIgnoreCase(command, "SET") or
        std.ascii.eqlIgnoreCase(command, "GSET") or
        std.ascii.eqlIgnoreCase(command, "INCR") or
        std.ascii.eqlIgnoreCase(command, "DECR") or
        std.ascii.eqlIgnoreCase(command, "APPEND") or
        std.ascii.eqlIgnoreCase(command, "EXPIRE") or
        std.ascii.eqlIgnoreCase(command, "PERSIST"))
        return keyAllowed(permissions.write, argumentKey(args, 1));
    if (std.ascii.eqlIgnoreCase(command, "DELETE"))
        return keyAllowed(permissions.delete, argumentKey(args, 1));
    if (std.ascii.eqlIgnoreCase(command, "MSET") or std.ascii.eqlIgnoreCase(command, "MSETNX")) {
        var index: usize = 1;
        while (index < args.len) : (index += 2) if (!keyAllowed(permissions.write, args[index])) return false;
        return true;
    }
    if (std.ascii.eqlIgnoreCase(command, "COPY"))
        return keyAllowed(permissions.read, argumentKey(args, 1)) and keyAllowed(permissions.write, argumentKey(args, 2));
    if (std.ascii.eqlIgnoreCase(command, "RENAME"))
        return keyAllowed(permissions.read, argumentKey(args, 1)) and
            keyAllowed(permissions.delete, argumentKey(args, 1)) and
            keyAllowed(permissions.write, argumentKey(args, 2));
    if (std.ascii.eqlIgnoreCase(command, "KEYS")) return hasWildcard(permissions.read);
    return true;
}

fn argumentKey(args: []const ZType, index: usize) ZType {
    return if (index < args.len) args[index] else .{ .int = 0 };
}

fn keyAllowed(prefixes: []const []const u8, value: ZType) bool {
    if (value != .str) return false;
    for (prefixes) |prefix| {
        if (std.mem.eql(u8, prefix, "*") or std.mem.startsWith(u8, value.str, prefix)) return true;
    }
    return false;
}

fn hasWildcard(prefixes: []const []const u8) bool {
    for (prefixes) |prefix| if (std.mem.eql(u8, prefix, "*")) return true;
    return false;
}
