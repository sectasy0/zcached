const std = @import("std");
const utils = @import("utils.zig");
const NodeIndex = utils.NodeIndex;

pub const DEFAULT_PATH: []const u8 = "./zcached.conf.zon";

const Config = @This();

pub const AOFConfig = struct {
    pub const FlushStrategy = enum { always, everysec, auto, no };
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
    rewrite_min_size: usize = 64 * 1024 * 1024, // 64MB
    rewrite_buffer_size: usize = 64 * 1024, // 64KB
    rewrite_buffer_max_size: usize = 256 * 1024, // 256KB

    const Fields = enum {
        flush_strategy,
        path,
        rewrite_percentage,
        rewrite_min_size,
    };
};

pub const TLSConfig = struct {
    enabled: bool = false,
    // Path to the certificate file
    cert_path: ?[]const u8 = null,
    // Path to the private key file
    key_path: ?[]const u8 = null,
    // Path to the CA certificate file
    ca_path: ?[]const u8 = null,
    // Whether to verify peer certificates
    // If true, the server will verify the peer's certificate against the CA certificate.
    verify_mode: TLSConfig.VerifyMode = .none,

    pub const VerifyMode = enum {
        none, // No verification
        peer, // Verify peer's certificate
        fail_if_no_peer_cert, // Fail if no peer certificate is provided
        client_once, // Verify client certificate once
    };

    const Fields = enum {
        enabled,
        cert_path,
        key_path,
        ca_path,
        verify_mode,
    };
};

address: std.net.Address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 7556),

loger_path: []const u8 = DEFAULT_PATH,

// maximum connections per thread
// to calculate global max connctions: `workers` * `max_clients`
max_clients: usize = 512,
max_memory: usize = 0, // 0 means unlimited, value in bytes
client_buffer: usize = 4096, // its resized if more space is requied
workers: usize = 4,

aof: AOFConfig = .{},
tls: TLSConfig = .{},

whitelist: std.ArrayList(std.net.Address) = undefined,
max_request_size: usize = 10 * 1024 * 1024, // 0 means unlimited, value in bytes

allocator: std.mem.Allocator,

pub fn deinit(config: *const Config) void {
    config.whitelist.deinit();
    if (config.tls.cert_path != null) config.allocator.free(config.tls.cert_path.?);
    if (config.tls.key_path != null) config.allocator.free(config.tls.key_path.?);
    if (config.tls.ca_path != null) config.allocator.free(config.tls.ca_path.?);
    if (config.aof.path != null) config.allocator.free(config.aof.path.?);
}

pub fn getAddress(self: *const Config) std.net.Address {
    return self.address;
}

pub fn load(allocator: std.mem.Allocator, file_path: ?[]const u8, log_path: ?[]const u8) !Config {
    var path: []const u8 = DEFAULT_PATH;
    if (file_path != null) path = file_path.?;

    var config = Config{
        .allocator = allocator,
        .whitelist = std.ArrayList(std.net.Address).init(allocator),
    };
    if (log_path != null) config.loger_path = log_path.?;

    var timestamp: [40]u8 = undefined;
    const t_size = utils.timestampf(&timestamp);

    std.debug.print(
        "INFO [{s}] * loading config file from: {s}\n",
        .{ timestamp[0..t_size], path },
    );

    utils.createPath(path);

    const file = std.fs.cwd().openFile(path, .{ .mode = .read_only }) catch |err| {
        // if the file doesn't exist, just return the default config
        if (err == error.FileNotFound) return config;
        return err;
    };
    defer file.close();

    const file_size = (try file.stat()).size;
    const config_bytes = try file.readToEndAllocOptions(
        allocator,
        file_size,
        null,
        1,
        0,
    );
    defer allocator.free(config_bytes);

    var ast = try std.zig.Ast.parse(allocator, config_bytes, .zon);
    defer ast.deinit(allocator);

    try processAst(&config, ast);

    return config;
}

const ConfigField = enum {
    address,
    port,
    max_clients,
    max_memory,
    max_request_size,
    workers,
    client_buffer,
    tls,
    aof,
    whitelist,
};

fn processAst(config: *Config, ast: std.zig.Ast) !void {
    var buf: [2]NodeIndex = undefined;
    const root = ast.fullStructInit(
        &buf,
        ast.nodes.items(.data)[0].lhs,
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

        processField(
            config,
            &buf,
            ast,
            root,
            field_name,
            field_idx,
        ) catch continue;
    }
}

const Node = union(enum) {
    null,
    bool: bool,

    int: u64,
    float: f64,
    string: []const u8,
    @"enum": []const u8,

    object: std.StringArrayHashMapUnmanaged(Node),
    empty, // .{}
};

fn processField(
    config: *Config,
    buf: *[2]NodeIndex,
    ast: std.zig.Ast,
    root: std.zig.Ast.full.StructInit,
    field_name: []const u8,
    field_idx: u32,
) !void {
    const allocator = config.allocator;

    if (ast.fullStructInit(buf, field_idx)) |v| {
        var object = std.StringArrayHashMapUnmanaged(Node){};
        defer {
            object.clearAndFree(config.allocator);
            object.deinit(config.allocator);
        }

        for (v.ast.fields) |i| {
            const token_index = ast.firstToken(i) - 2;
            const token_name = ast.tokenSlice(token_index);

            const node = ast.nodes.get(i);

            var timestamp: [40]u8 = undefined;
            const t_size = utils.timestampf(&timestamp);

            switch (node.tag) {
                .number_literal => {
                    const value = utils.parseNumber(ast, i);

                    object.put(allocator, token_name, .{ .int = value.int }) catch |err| {
                        std.debug.print(
                            "ERROR [{d}] * Failed to put number literal into object: {?}\n",
                            .{ timestamp[0..t_size], err },
                        );
                        continue;
                    };
                },
                .string_literal => {
                    const value = try utils.parseString(allocator, ast, i);

                    object.put(allocator, token_name, .{ .string = value }) catch |err| {
                        std.debug.print(
                            "ERROR [{d}] * Failed to put string literal into object: {?}\n",
                            .{ timestamp[0..t_size], err },
                        );
                        continue;
                    };
                },
                .enum_literal => {
                    const value = ast.tokenSlice(node.main_token);

                    object.put(allocator, token_name, .{ .@"enum" = value }) catch |err| {
                        std.debug.print(
                            "ERROR [{d}] * Failed to put enum literal into object: {?}\n",
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
                                "ERROR [{d}] * Failed to put identifier into object: {?}\n",
                                .{ timestamp[0..t_size], err },
                            );
                            continue;
                        };
                    } else {
                        object.put(allocator, token_name, .{ .bool = false }) catch |err| {
                            std.debug.print(
                                "ERROR [{d}] * Failed to put identifier into object: {?}\n",
                                .{ timestamp[0..t_size], err },
                            );
                            continue;
                        };
                    }
                },
                else => {
                    std.debug.print(
                        "WARN [{d}] * Unsupported node tag: {s}, skipping\n",
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
        var result: std.ArrayList(std.net.Address) = .init(allocator);
        errdefer result.deinit();

        for (v.ast.elements) |v_idx| {
            const value = utils.parseString(
                allocator,
                ast,
                v_idx,
            ) catch return;
            defer allocator.free(value);

            const parsed = std.net.Address.parseIp(
                value,
                config.address.getPort(),
            ) catch |err| {
                var timestamp: [40]u8 = undefined;
                const t_size = utils.timestampf(&timestamp);
                std.debug.print(
                    "ERROR [{d}] * parsing {s} as std.net.Address, {?}\n",
                    .{ timestamp[0..t_size], value, err },
                );
                return;
            };

            try result.append(parsed);
        }

        try assignFieldValue(config, field_name, result);

        return;
    }

    const node: u32 = root.ast.fields[field_idx - 1];
    const info: std.zig.Ast.Node = ast.nodes.get(node);

    try parseByNodeTag(
        config,
        allocator,
        field_name,
        ast,
        info,
        field_idx,
    );
}

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
                        "ERROR [{d}] * Failed to parse number literal: {}\n",
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

fn assignFieldValue(config: *Config, field_name: []const u8, value: anytype) !void {
    const config_field = std.meta.stringToEnum(ConfigField, field_name) orelse {
        return;
    };

    switch (config_field) {
        .address => {
            if (@TypeOf(value) != []const u8) return;

            const parsed = std.net.Address.parseIp(value, config.address.getPort()) catch |err| {
                var timestamp: [40]u8 = undefined;
                const t_size = utils.timestampf(&timestamp);
                std.debug.print(
                    "ERROR [{s}] * parsing {s} as std.net.Address, {?}\n",
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
                    std.debug.print("[ERROR {d}] Unknown field: {s}\n", .{ timestamp[0..t_size], k });
                    continue;
                };

                switch (field) {
                    .enabled => {
                        if (std.meta.activeTag(v) != .bool) {
                            std.debug.print("ERROR [{d}] Unknown enabled type: {any}\n", .{
                                timestamp[0..t_size],
                                v,
                            });
                            continue;
                        }

                        tls_config.enabled = v.bool;
                    },
                    .cert_path => {
                        if (std.meta.activeTag(v) != .string) {
                            std.debug.print("ERROR [{d}] Unknown cert_path type: {any}\n", .{
                                timestamp[0..t_size],
                                v,
                            });
                            continue;
                        }

                        tls_config.cert_path = v.string;
                    },
                    .key_path => {
                        if (std.meta.activeTag(v) != .string) {
                            std.debug.print("ERROR [{d}] Unknown key_path type: {any}\n", .{
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
                                std.debug.print("ERROR [{d}] Unknown ca_path type: {any}\n", .{
                                    timestamp[0..t_size],
                                    v,
                                });
                                continue;
                            },
                        }
                    },
                    .verify_mode => {
                        if (std.meta.activeTag(v) != .@"enum") {
                            std.debug.print("ERROR [{d}] Unknown verify_mode type: {any}\n", .{
                                timestamp[0..t_size],
                                v,
                            });
                            continue;
                        }

                        const verify_mode = std.meta.stringToEnum(TLSConfig.VerifyMode, v.@"enum") orelse {
                            std.debug.print("ERROR [{d}] Unknown verify_mode: {s}\n", .{
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
            if (@TypeOf(value) != std.ArrayList(std.net.Address)) return;

            const old_whitelist = config.whitelist;
            defer old_whitelist.deinit();

            config.whitelist = value;
        },
    }
}
