const std = @import("std");
const utils = @import("utils.zig");
const NodeIndex = utils.NodeIndex;

pub const DEFAULT_PATH: []const u8 = "./zcached.conf.zon";

const Config = @This();

address: std.net.Address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 7556),

loger_path: []const u8 = DEFAULT_PATH,

// maximum connections per thread
// to calculate global max connctions: `workers` * `max_clients`
max_clients: usize = 512,
max_memory: usize = 0, // 0 means unlimited, value in bytes
cbuffer: usize = 4096, // its resized if more space is requied
workers: usize = 4,

secure_transport: bool = false,
cert_path: ?[]const u8 = null,
key_path: ?[]const u8 = null,

whitelist: std.ArrayList(std.net.Address) = undefined,
max_request_size: usize = 10 * 1024 * 1024, // 0 means unlimited, value in bytes

allocator: std.mem.Allocator,

pub fn deinit(config: *const Config) void {
    config.whitelist.deinit();
    if (config.cert_path != null) config.allocator.free(config.cert_path.?);
    if (config.key_path != null) config.allocator.free(config.key_path.?);
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

    utils.create_path(path);

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

    try process_ast(&config, ast);

    return config;
}

const ConfigField = enum {
    address,
    port,
    max_clients,
    max_memory,
    max_request_size,
    workers,
    cbuffer,
    secure_transport,
    cert_path,
    key_path,
    whitelist,
};

fn process_ast(config: *Config, ast: std.zig.Ast) !void {
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

        process_field(
            config,
            &buf,
            ast,
            root,
            field_name,
            field_idx,
        ) catch continue;
    }
}

fn process_field(
    config: *Config,
    buf: *[2]NodeIndex,
    ast: std.zig.Ast,
    root: std.zig.Ast.full.StructInit,
    field_name: []const u8,
    field_idx: u32,
) !void {
    const allocator = config.allocator;

    if (ast.fullStructInit(buf, field_idx)) |_| return;

    if (ast.fullArrayInit(buf, field_idx)) |v| {
        var result = std.ArrayList(std.net.Address).init(allocator);
        errdefer result.deinit();

        for (v.ast.elements) |v_idx| {
            const value = utils.parse_string(
                allocator,
                ast,
                v_idx,
            ) catch return;
            defer allocator.free(value);

            const parsed = std.net.Address.parseIp(
                value,
                config.address.getPort(),
            ) catch |err| {
                std.debug.print(
                    "ERROR [{d}] * parsing {s} as std.net.Address, {?}\n",
                    .{ std.time.timestamp(), value, err },
                );
                return;
            };

            try result.append(parsed);
        }

        try assign_field_value(config, field_name, result);

        return;
    }

    const node: u32 = root.ast.fields[field_idx - 1];
    const info: std.zig.Ast.Node = ast.nodes.get(node);

    switch (info.tag) {
        std.zig.Ast.Node.Tag.number_literal => {
            const value = utils.parse_number(ast, field_idx);

            try assign_field_value(config, field_name, value.int);
        },
        std.zig.Ast.Node.Tag.string_literal => {
            const Booleans = enum { true, false, True, False };

            const value = try utils.parse_string(allocator, ast, field_idx);
            defer allocator.free(value);

            const boolean_result = std.meta.stringToEnum(Booleans, value) orelse {
                return try assign_field_value(config, field_name, value);
            };
            switch (boolean_result) {
                .true, .True => try assign_field_value(config, field_name, true),
                .false, .False => try assign_field_value(config, field_name, false),
            }
        },
        else => return,
    }
}

fn assign_field_value(config: *Config, field_name: []const u8, value: anytype) !void {
    const config_field = std.meta.stringToEnum(ConfigField, field_name) orelse {
        return;
    };

    switch (config_field) {
        .address => {
            if (@TypeOf(value) != []const u8) return;

            const parsed = std.net.Address.parseIp(value, config.address.getPort()) catch |err| {
                std.debug.print(
                    "ERROR [{d}] * parsing {s} as std.net.Address, {?}\n",
                    .{ std.time.timestamp(), value, err },
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
        .cbuffer => {
            if (@TypeOf(value) != u64) return;
            config.cbuffer = value;
        },
        .secure_transport => {
            if (@TypeOf(value) != bool) return;
            config.secure_transport = value;
        },
        .cert_path => {
            if (@TypeOf(value) != []const u8) return;
            config.cert_path = try config.allocator.dupe(u8, value);
        },
        .key_path => {
            if (@TypeOf(value) != []const u8) return;
            config.key_path = try config.allocator.dupe(u8, value);
        },
        .whitelist => {
            if (@TypeOf(value) != std.ArrayList(std.net.Address)) return;

            const old_whitelist = config.whitelist;
            defer old_whitelist.deinit();

            config.whitelist = value;
        },
    }
}
