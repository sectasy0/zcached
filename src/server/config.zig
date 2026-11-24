//! Defines server configuration defaults and loads values from a Zig Object Notation file.

const std = @import("std");
const fs = @import("fs");
const utils = @import("utils.zig");
const NodeIndex = std.zig.Ast.Node.Index;
const Address = @import("network/address.zig").Address;

pub const NetworkConfig = struct {
    idle_timeout_ms: u32 = 0,
    request_timeout_ms: u32 = 0,
    max_pending_response_bytes: usize = 0,
};

pub const SnapshotConfig = struct {
    path: ?[]const u8 = null,
    interval_secs: u32 = 0,
    keep_last: usize = 0,
};

pub const LogConfig = struct {
    level: enum { debug, info, warning, @"error" } = .debug,
};

/// Default path used when no configuration file is supplied.
pub const DEFAULT_PATH: []const u8 = "./zcached.conf.zon";

/// Server settings, including defaults and allocator-owned parsed values.
const Config = @This();

pub const Memory = struct {
    /// Number of memory shards; must be positive.
    shard_count: usize = 16,
    /// Initial entry capacity per shard.
    default_capacity: usize = 64,
    /// Global requested-byte limit; zero falls back to `max_memory`.
    limit: usize = 0,

    const Fields = enum {
        shard_count,
        default_capacity,
        limit,
    };
};

/// Append-only-file persistence and rewrite settings.
pub const AOFConfig = struct {
    /// Policy controlling when append-only data is flushed.
    pub const FlushStrategy = enum {
        /// Flush after each write operation.
        always,
        /// Flush periodically, normally once per second.
        everysec,
        /// Choose flushing behavior automatically.
        auto,
        /// Do not flush automatically.
        no,
    };
    /// Flush strategy for the AOF file.
    /// Options: "always", "everysec", "no", default: "everysec"
    /// - "always" - flush every write operation (not recommended for performance)
    /// - "everysec" - flush every second (default)
    /// - "no" - never flush, only write to the file (not recommended for performance)
    ///   and can lead to data loss in case of a crash
    /// If you want to disable AOF, set `flush_strategy` to `no`.
    flush_strategy: AOFConfig.FlushStrategy = .everysec, // default: "everysec"
    /// Path to the AOF file.
    path: ?[]const u8 = null,
    /// Percentage of the AOF file to rewrite.
    rewrite_percentage: u32 = 100, // 100%
    /// Minimum size of the AOF file to rewrite.
    /// Minimum AOF size that permits a rewrite.
    rewrite_min_size: usize = 64 * 1024 * 1024, // 64MB
    /// Initial buffer capacity used while rewriting the AOF.
    rewrite_buffer_size: usize = 64 * 1024, // 64KB
    /// Maximum buffer capacity used while rewriting the AOF.
    rewrite_buffer_max_size: usize = 256 * 1024, // 256KB

    /// Configuration keys recognized inside the AOF section.
    const Fields = enum {
        flush_strategy,
        path,
        rewrite_percentage,
        rewrite_min_size,
    };
};

/// Initial capacities and retry timing for background-agent queues.
pub const AgentConfig = struct {
    /// Initial capacity of each background worker queue.
    // Default capacity of the background worker queues
    // Queues size are dynamic, this is just the initial capacity
    default_capacity: usize = 64,
    /// Maximum retries when a task cannot be rescheduled.
    // Number of times to retry rescheduling a task if rescheduling fails
    reschedule_retries: usize = 5,
    /// Delay between reschedule retries, in milliseconds.
    // Delay between reschedule retries in milliseconds
    reschedule_retry_delay_ms: u64 = 100,

    /// Configuration keys recognized in the agent section.
    const Fields = enum {
        default_capacity,
        reschedule_retries,
        reschedule_retry_delay_ms,
    };
};

/// TLS activation, certificate paths, and peer-verification policy.
pub const TLSConfig = struct {
    /// Whether TLS is enabled for the server.
    enabled: bool = false,
    /// Path to a PEM server certificate chain file, with the leaf certificate first.
    cert_path: ?[]const u8 = null,
    /// Path to the PEM private key matching the server certificate.
    key_path: ?[]const u8 = null,
    /// Path to a PEM CA bundle used to validate client certificates.
    ca_path: ?[]const u8 = null,
    /// Whether to request and verify client certificates during the TLS handshake.
    verify_mode: TLSConfig.VerifyMode = .none,

    /// Available peer certificate verification modes.
    pub const VerifyMode = enum {
        /// Do not request or verify client certificates.
        none,
        /// Verify a provided client certificate, but allow clients without one.
        peer,
        /// Require and verify a client certificate.
        fail_if_no_peer_cert,
        /// Verify a provided client certificate once; does not require one.
        client_once,
    };

    /// Rejects incomplete or unsafe TLS settings before opening certificate files.
    pub fn validate(self: TLSConfig) !void {
        if (!self.enabled) return;

        const cert_path = self.cert_path orelse return error.InvalidTLSConfig;
        const key_path = self.key_path orelse return error.InvalidTLSConfig;
        if (!validTLSPath(cert_path) or !validTLSPath(key_path)) return error.InvalidTLSConfig;
        if (self.ca_path) |path| {
            if (!validTLSPath(path)) return error.InvalidTLSConfig;
        }
        if (self.verify_mode != .none and self.ca_path == null) return error.InvalidTLSConfig;
    }

    fn validTLSPath(path: []const u8) bool {
        return path.len > 0 and std.mem.indexOfScalar(u8, path, 0) == null;
    }

    /// Configuration keys recognized in the TLS section.
    const Fields = enum {
        enabled,
        cert_path,
        key_path,
        ca_path,
        verify_mode,
    };
};

/// Listening address, including its port.
address: Address = Address.initIp4(.{ 127, 0, 0, 1 }, 7556),

/// Log file path used when initializing the logger.
loger_path: []const u8 = DEFAULT_PATH,

// maximum connections per worker thread
// to calculate global max connctions: `workers` * `max_clients`
/// Maximum client connections assigned to each worker thread.
max_clients: usize = 512,
/// Legacy fallback for `memory.limit`; zero means unlimited.
max_memory: usize = 0, // 0 means unlimited, value in bytes
/// Initial client buffer size in bytes; it may grow for larger payloads.
client_buffer: usize = 4096, // its resized if more space is requied
/// Number of worker threads.
workers: usize = 4,
/// Whether request and response payloads are included in logs; disabled by default.
log_network_payloads: bool = false,

/// Settings for append-only persistence.
aof: AOFConfig = .{},
/// Settings for secure transport.
tls: TLSConfig = .{},
/// Settings for background task queues.
agent: AgentConfig = .{},
/// Sharding settings; a zero section limit falls back to `max_memory`.
memory: Memory = .{},
network: NetworkConfig = .{},
snapshot: SnapshotConfig = .{},
log: LogConfig = .{},

/// IP addresses permitted by the access middleware; storage is owned by this config.
whitelist: std.array_list.Managed(Address) = undefined,
/// Maximum request size in bytes; zero means unlimited.
max_request_size: usize = 10 * 1024 * 1024, // 0 means unlimited, value in bytes

/// Allocator used for whitelist storage and parsed TLS/AOF path strings.
allocator: std.mem.Allocator,

/// Releases the whitelist and parsed paths allocated from `allocator`.
pub fn deinit(config: *const Config) void {
    config.whitelist.deinit();
    if (config.tls.cert_path != null) config.allocator.free(config.tls.cert_path.?);
    if (config.tls.key_path != null) config.allocator.free(config.tls.key_path.?);
    if (config.tls.ca_path != null) config.allocator.free(config.tls.ca_path.?);
    if (config.aof.path != null) config.allocator.free(config.aof.path.?);
    if (config.snapshot.path) |path| config.allocator.free(path);
}

/// Returns the configured listening address by value.
pub fn getAddress(self: *const Config) Address {
    return self.address;
}

/// Loads defaults and applies values from an optional ZON file.
/// A missing file leaves defaults intact; I/O and allocation errors are propagated.
/// Parsed path strings and whitelist storage are owned by the returned config.
pub fn load(allocator: std.mem.Allocator, file_path: ?[]const u8, log_path: ?[]const u8) !Config {
    var path: []const u8 = DEFAULT_PATH;
    if (file_path != null) path = file_path.?;

    var config = Config{
        .allocator = allocator,
        .whitelist = std.array_list.Managed(Address).init(allocator),
    };
    errdefer config.deinit();
    if (log_path != null) config.loger_path = log_path.?;

    var timestamp: [40]u8 = undefined;
    const t_size = utils.timestampf(&timestamp);

    std.debug.print(
        "INFO [{s}] * loading config file from: {s}\n",
        .{ timestamp[0..t_size], path },
    );

    utils.createPath(path);

    const file = fs.cwd().openFile(path, .{ .mode = .read_only }) catch |err| {
        // if the file doesn't exist, just return the default config
        if (err == error.FileNotFound) return config;
        return err;
    };
    defer file.close();

    const file_size = (try file.stat()).size;
    const config_bytes = try file.readToEndAllocOptions(
        allocator,
        file_size,
        0,
        .@"1",
        0,
    );
    defer allocator.free(config_bytes);

    var ast = try std.zig.Ast.parse(allocator, config_bytes, .{ .mode = .zon });
    defer ast.deinit(allocator);

    try processAst(&config, ast);

    return config;
}

/// Top-level configuration keys accepted by the ZON parser.
const ConfigField = enum {
    address,
    port,
    max_clients,
    max_memory,
    max_request_size,
    workers,
    client_buffer,
    log_network_payloads,
    tls,
    aof,
    memory,
    whitelist,
};

/// Validates the ZON root and applies each declared field, logging malformed roots.
fn processAst(config: *Config, ast: std.zig.Ast) !void {
    var buf: [2]NodeIndex = undefined;
    var child_buf: [2]NodeIndex = undefined;
    if (ast.errors.len > 0) {
        var timestamp: [40]u8 = undefined;
        const t_size = utils.timestampf(&timestamp);
        std.debug.print(
            "WARN [{s}] * Failed to parse config, invalid `.zon` file, default values will be used\n",
            .{timestamp[0..t_size]},
        );

        return;
    }

    const root_decls = ast.rootDecls();
    if (root_decls.len == 0) {
        var timestamp: [40]u8 = undefined;
        const t_size = utils.timestampf(&timestamp);
        std.debug.print(
            "WARN [{s}] * Failed to parse config, empty `.zon` root, default values will be used\n",
            .{timestamp[0..t_size]},
        );

        return;
    }

    const root = ast.fullStructInit(
        &child_buf,
        root_decls[0],
    ) orelse {
        var timestamp: [40]u8 = undefined;
        const t_size = utils.timestampf(&timestamp);
        std.debug.print(
            "WARN [{s}] * Failed to parse config, invalid `.zon` file, default values will be used\n",
            .{timestamp[0..t_size]},
        );

        return;
    };

    for (root.ast.fields) |field_idx| {
        const field_name = ast.tokenSlice(ast.firstToken(field_idx) - 2);
        const source = ast.getNodeSource(field_idx);
        if (std.mem.eql(u8, field_name, "network")) {
            config.network = try parseSection(NetworkConfig, config.allocator, source);
            continue;
        }
        if (std.mem.eql(u8, field_name, "snapshot")) {
            const snapshot = try parseSection(SnapshotConfig, config.allocator, source);
            if (config.snapshot.path) |path| config.allocator.free(path);
            config.snapshot = snapshot;
            continue;
        }
        if (std.mem.eql(u8, field_name, "log")) {
            config.log = try parseSection(LogConfig, config.allocator, source);
            continue;
        }

        processField(
            config,
            &buf,
            ast,
            field_name,
            field_idx,
        ) catch continue;
    }
}

fn parseSection(T: type, allocator: std.mem.Allocator, source: []const u8) !T {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    var result = std.zon.parse.fromSlice(T, .{
        .gpa = allocator,
        .arena = arena,
        .source = try arena.dupeSentinel(u8, source, 0),
        .diagnostics = &diagnostics,
    }) catch |err| {
        if (err == error.ParseZon) std.debug.print("{f}", .{diagnostics.fmt(@typeName(T))});
        return err;
    };
    if (T == SnapshotConfig) {
        if (result.path) |path| {
            if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null)
                return error.InvalidSnapshotPath;
            result.path = try allocator.dupe(u8, path);
        }
    }
    return result;
}

/// Intermediate values decoded from ZON syntax before assignment to configuration.
const Node = union(enum) {
    /// Explicit null literal.
    null,
    /// Boolean literal value.
    bool: bool,

    /// Non-negative integer literal value.
    int: u64,
    /// Floating-point literal value.
    float: f64,
    /// Decoded string literal.
    string: []const u8,
    /// Name of an enum literal.
    @"enum": []const u8,

    /// Object members preserved by key during section parsing.
    object: std.StringArrayHashMapUnmanaged(Node),
    /// Empty object literal.
    empty, // .{}
};

/// Decodes one root field, including nested objects and address lists.
fn processField(
    config: *Config,
    buf: *[2]NodeIndex,
    ast: std.zig.Ast,
    field_name: []const u8,
    field_idx: NodeIndex,
) !void {
    const allocator = config.allocator;

    const field_index = @backingInt(field_idx);

    if (ast.fullStructInit(buf, field_idx)) |v| {
        var object = std.StringArrayHashMapUnmanaged(Node){};
        defer {
            object.clearAndFree(config.allocator);
            object.deinit(config.allocator);
        }

        for (v.ast.fields) |i| {
            const token_index = ast.firstToken(i) - 2;
            const token_name = ast.tokenSlice(token_index);

            const index = @backingInt(i);

            const node = ast.nodes.get(index);

            var timestamp: [40]u8 = undefined;
            const t_size = utils.timestampf(&timestamp);

            switch (node.tag) {
                .number_literal => {
                    const value = utils.parseNumber(ast, index);

                    object.put(allocator, token_name, .{ .int = value.int }) catch |err| {
                        std.debug.print(
                            "ERROR [{s}] * Failed to put number literal into object: {any}\n",
                            .{ timestamp[0..t_size], err },
                        );
                        continue;
                    };
                },
                .string_literal => {
                    const value = try utils.parseString(allocator, ast, index);

                    object.put(allocator, token_name, .{ .string = value }) catch |err| {
                        std.debug.print(
                            "ERROR [{s}] * Failed to put string literal into object: {any}\n",
                            .{ timestamp[0..t_size], err },
                        );
                        continue;
                    };
                },
                .enum_literal => {
                    const value = ast.tokenSlice(node.main_token);

                    object.put(allocator, token_name, .{ .@"enum" = value }) catch |err| {
                        std.debug.print(
                            "ERROR [{s}] * Failed to put enum literal into object: {any}\n",
                            .{ timestamp[0..t_size], err },
                        );
                        continue;
                    };
                },
                .identifier => {
                    const value: []const u8 = ast.tokenSlice(node.main_token);

                    if (std.mem.eql(u8, value, "true")) {
                        object.put(allocator, token_name, .{ .bool = true }) catch |err| {
                            std.debug.print(
                                "ERROR [{s}] * Failed to put identifier into object: {any}\n",
                                .{ timestamp[0..t_size], err },
                            );
                            continue;
                        };
                    } else {
                        object.put(allocator, token_name, .{ .bool = false }) catch |err| {
                            std.debug.print(
                                "ERROR [{s}] * Failed to put identifier into object: {any}\n",
                                .{ timestamp[0..t_size], err },
                            );
                            continue;
                        };
                    }
                },
                else => {
                    std.debug.print(
                        "WARN [{s}] * Unsupported node tag: {s}, skipping\n",
                        .{ timestamp[0..t_size], @tagName(node.tag) },
                    );
                    continue;
                },
            }
        }

        try assignFieldValue(config, field_name, object);

        return;
    }

    if (ast.fullArrayInit(buf, field_idx)) |v| {
        var result: std.array_list.Managed(Address) = .init(allocator);
        errdefer result.deinit();

        for (v.ast.elements) |v_idx| {
            const index = @backingInt(v_idx);
            const value = utils.parseString(
                allocator,
                ast,
                index,
            ) catch return;
            defer allocator.free(value);

            const parsed = Address.parseIp(
                value,
                config.address.getPort(),
            ) catch |err| {
                var timestamp: [40]u8 = undefined;
                const t_size = utils.timestampf(&timestamp);
                std.debug.print(
                    "ERROR [{s}] * parsing {s} as network Address, {any}\n",
                    .{ timestamp[0..t_size], value, err },
                );
                return;
            };

            try result.append(parsed);
        }

        try assignFieldValue(config, field_name, result);

        return;
    }

    const info = ast.nodes.get(field_index);

    try parseByNodeTag(
        config,
        allocator,
        field_name,
        ast,
        info,
        field_index,
    );
}

/// Interprets a scalar AST node and forwards supported values for assignment.
fn parseByNodeTag(
    config: *Config,
    allocator: std.mem.Allocator,
    field_name: []const u8,
    ast: std.zig.Ast,
    node: std.zig.Ast.Node,
    index: u32,
) !void {
    switch (node.tag) {
        .number_literal => {
            const value: std.zig.number_literal.Result = utils.parseNumber(ast, index);
            switch (value) {
                .failure => {
                    var timestamp: [40]u8 = undefined;
                    const t_size = utils.timestampf(&timestamp);
                    std.debug.print(
                        "ERROR [{s}] * Failed to parse number literal: {}\n",
                        .{ timestamp[0..t_size], value.failure },
                    );
                    return;
                },
                else => try assignFieldValue(config, field_name, value.int),
            }
        },
        .string_literal => {
            const value: []const u8 = try utils.parseString(allocator, ast, index);
            defer allocator.free(value);

            return try assignFieldValue(config, field_name, value);
        },
        .enum_literal => {
            const value: []const u8 = ast.tokenSlice(node.main_token);

            return try assignFieldValue(config, field_name, value);
        },
        .identifier => {
            const value: []const u8 = ast.tokenSlice(node.main_token);

            if (std.mem.eql(u8, value, "true")) {
                return try assignFieldValue(config, field_name, true);
            } else {
                return try assignFieldValue(config, field_name, false);
            }
        },
        else => return,
    }
}

/// Type-checks and applies a decoded value to the matching configuration setting.
/// Unknown fields and mismatched value types are ignored; address parse failures are logged.
fn assignFieldValue(config: *Config, field_name: []const u8, value: anytype) !void {
    const config_field = std.meta.stringToEnum(ConfigField, field_name) orelse {
        return;
    };

    switch (config_field) {
        .address => {
            if (@TypeOf(value) != []const u8) return;

            const parsed = Address.parseIp(value, config.address.getPort()) catch |err| {
                var timestamp: [40]u8 = undefined;
                const t_size = utils.timestampf(&timestamp);
                std.debug.print(
                    "ERROR [{s}] * parsing {s} as network Address, {any}\n",
                    .{ timestamp[0..t_size], value, err },
                );
                return;
            };

            config.address = parsed;
        },
        .port => {
            if (@TypeOf(value) != u64) return;
            config.address.setPort(@as(u16, @truncate(value)));
        },
        .max_clients => {
            if (@TypeOf(value) != u64) return;
            config.max_clients = value;
        },
        .max_memory => {
            if (@TypeOf(value) != u64) return;
            config.max_memory = value;
        },
        .max_request_size => {
            if (@TypeOf(value) != u64) return;
            config.max_request_size = value;
        },
        .workers => {
            if (@TypeOf(value) != u64) return;
            config.workers = value;
        },
        .client_buffer => {
            if (@TypeOf(value) != u64) return;
            config.client_buffer = value;
        },
        .log_network_payloads => {
            if (@TypeOf(value) != bool) return;
            config.log_network_payloads = value;
        },
        .memory => {
            if (@TypeOf(value) != std.StringArrayHashMapUnmanaged(Node)) return;
            var iterator = value.iterator();
            while (iterator.next()) |item| {
                const field = std.meta.stringToEnum(Memory.Fields, item.key_ptr.*) orelse {
                    std.debug.print("Unknown memory field: {s}\n", .{item.key_ptr.*});
                    continue;
                };
                const node = item.value_ptr.*;
                if (node != .int) {
                    std.debug.print("Invalid memory field type: {s}\n", .{item.key_ptr.*});
                    continue;
                }
                switch (field) {
                    .shard_count => config.memory.shard_count = @intCast(node.int),
                    .default_capacity => config.memory.default_capacity = @intCast(node.int),
                    .limit => config.memory.limit = @intCast(node.int),
                }
            }
        },
        .aof => {
            var aof_config: AOFConfig = .{};

            if (@TypeOf(value) != std.StringArrayHashMapUnmanaged(Node)) return;

            var iterator = value.iterator();
            while (iterator.next()) |item| {
                const k = item.key_ptr.*;
                const v = item.value_ptr.*;

                const field = std.meta.stringToEnum(AOFConfig.Fields, k) orelse {
                    std.debug.print("Unknown field: {s}\n", .{k});
                    continue;
                };

                switch (field) {
                    .flush_strategy => {
                        if (std.meta.activeTag(v) != .@"enum") {
                            std.debug.print("Unknown flush_strategy type: {any}\n", .{v});
                            continue;
                        }

                        const strategy = std.meta.stringToEnum(AOFConfig.FlushStrategy, v.@"enum") orelse {
                            std.debug.print("Unknown flush_strategy: {s}\n", .{v.string});
                            continue;
                        };

                        aof_config.flush_strategy = strategy;
                    },
                    .path => {
                        if (std.meta.activeTag(v) != .string) {
                            std.debug.print("Unknown path type: {any}\n", .{v});
                            continue;
                        }

                        aof_config.path = v.string;
                    },
                    .rewrite_percentage => {
                        if (std.meta.activeTag(v) != .int) {
                            std.debug.print("Unknown rewrite_percentage type: {any}\n", .{v});
                            continue;
                        }

                        aof_config.rewrite_percentage = @truncate(v.int);
                    },
                    .rewrite_min_size => {
                        if (std.meta.activeTag(v) != .int) {
                            std.debug.print("Unknown rewrite_min_size type: {any}\n", .{v});
                            continue;
                        }

                        aof_config.rewrite_min_size = @truncate(v.int);
                    },
                }
            }

            config.aof = aof_config;
        },
        .tls => {
            var tls_config: TLSConfig = .{};

            if (@TypeOf(value) != std.StringArrayHashMapUnmanaged(Node)) return;

            var iterator = value.iterator();
            while (iterator.next()) |item| {
                const k = item.key_ptr.*;
                const v = item.value_ptr.*;

                var timestamp: [40]u8 = undefined;
                const t_size = utils.timestampf(&timestamp);

                const field = std.meta.stringToEnum(TLSConfig.Fields, k) orelse {
                    std.debug.print("[ERROR {s}] Unknown field: {s}\n", .{ timestamp[0..t_size], k });
                    continue;
                };

                switch (field) {
                    .enabled => {
                        if (std.meta.activeTag(v) != .bool) {
                            std.debug.print("ERROR [{s}] Unknown enabled type: {any}\n", .{
                                timestamp[0..t_size],
                                v,
                            });
                            continue;
                        }

                        tls_config.enabled = v.bool;
                    },
                    .cert_path => {
                        if (std.meta.activeTag(v) != .string) {
                            std.debug.print("ERROR [{s}] Unknown cert_path type: {any}\n", .{
                                timestamp[0..t_size],
                                v,
                            });
                            continue;
                        }

                        tls_config.cert_path = v.string;
                    },
                    .key_path => {
                        if (std.meta.activeTag(v) != .string) {
                            std.debug.print("ERROR [{s}] Unknown key_path type: {any}\n", .{
                                timestamp[0..t_size],
                                v,
                            });
                            continue;
                        }

                        tls_config.key_path = v.string;
                    },
                    .ca_path => {
                        switch (std.meta.activeTag(v)) {
                            .null, .bool => tls_config.ca_path = null,
                            .string => tls_config.ca_path = v.string,
                            else => {
                                std.debug.print("ERROR [{s}] Unknown ca_path type: {any}\n", .{
                                    timestamp[0..t_size],
                                    v,
                                });
                                continue;
                            },
                        }
                    },
                    .verify_mode => {
                        if (std.meta.activeTag(v) != .@"enum") {
                            std.debug.print("ERROR [{s}] Unknown verify_mode type: {any}\n", .{
                                timestamp[0..t_size],
                                v,
                            });
                            continue;
                        }

                        const verify_mode = std.meta.stringToEnum(TLSConfig.VerifyMode, v.@"enum") orelse {
                            std.debug.print("ERROR [{s}] Unknown verify_mode: {s}\n", .{
                                timestamp[0..t_size],
                                v.string,
                            });
                            continue;
                        };

                        tls_config.verify_mode = verify_mode;
                    },
                }
            }

            config.tls = tls_config;
        },
        .whitelist => {
            if (@TypeOf(value) != std.array_list.Managed(Address)) return;

            const old_whitelist = config.whitelist;
            defer old_whitelist.deinit();

            config.whitelist = value;
        },
    }
}
