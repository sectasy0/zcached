const std = @import("std");
const utils = @import("utils.zig");

pub const DEFAULT_PATH: []const u8 = "./zcached.conf.zon";

const Config = @This();

address: std.net.Address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 7556),

loger_path: []const u8 = DEFAULT_PATH,

// maximum connections per thread
// to calculate global max connctions: `workers` * `maxclients`
maxclients: usize = 512,
maxmemory: usize = 0, // 0 means unlimited, value in bytes
cbuffer: usize = 4096, // its resized if more space is requied
workers: usize = 4,

whitelist: std.ArrayList(std.net.Address) = undefined,
proto_max_bulk_len: usize = 512 * 1024 * 1024, // 0 means unlimited, value in bytes

allocator: std.mem.Allocator,

pub fn deinit(config: *const Config) void {
    config.whitelist.deinit();
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
    maxclients,
    maxmemory,
    proto_max_bulk_len,
    workers,
    cbuffer,
    whitelist,
};

const AstNodeIndex = [2]std.zig.Ast.Node.Index;

fn process_ast(config: *Config, ast: std.zig.Ast) !void {
    var buf: AstNodeIndex = undefined;
    const root = ast.fullStructInit(&buf, ast.nodes.items(.data)[0].lhs) orelse {
        return error.ParseError;
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
    buf: *AstNodeIndex,
    ast: std.zig.Ast,
    root: std.zig.Ast.full.StructInit,
    field_name: []const u8,
    field_idx: u32,
) !void {
    const allocator = config.allocator;

    if (ast.fullStructInit(buf, field_idx)) |_| return;
    // if (ast.fullArrayInit(buf, field_idx)) |_| return;

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

            const parsed = utils.parse_address(
                value,
                config.address.getPort(),
            ) orelse return;

            try result.append(parsed);
        }

        try assign_field_value(config, field_name, result);

        return;
    }

    const node = root.ast.fields[field_idx - 1];
    const info: std.zig.Ast.Node = ast.nodes.get(node);

    switch (info.tag) {
        std.zig.Ast.Node.Tag.number_literal => {
            const value = utils.parse_number(ast, field_idx);

            try assign_field_value(config, field_name, value.int);
        },
        std.zig.Ast.Node.Tag.string_literal => {
            const value = try utils.parse_string(allocator, ast, field_idx);
            defer allocator.free(value);

            try assign_field_value(config, field_name, value);
        },

        else => return,
    }
}

fn assign_field_value(config: *Config, field_name: []const u8, value: anytype) !void {
    const config_field = std.meta.stringToEnum(ConfigField, field_name);
    if (config_field == null) return;

    switch (config_field.?) {
        .address => {
            if (@TypeOf(value) != []const u8) return;

            const parsed = utils.parse_address(value, config.address.getPort());
            if (parsed == null) return;

            config.address = parsed.?;
        },
        .port => {
            if (@TypeOf(value) != u64) return;

            config.address.setPort(@as(u16, @truncate(value)));
        },
        .maxclients => {
            if (@TypeOf(value) != u64) return;

            config.maxclients = value;
        },
        .maxmemory => {
            if (@TypeOf(value) != u64) return;

            config.maxmemory = value;
        },
        .proto_max_bulk_len => {
            if (@TypeOf(value) != u64) return;

            config.proto_max_bulk_len = value;
        },
        .workers => {
            if (@TypeOf(value) != u64) return;

            config.workers = value;
        },
        .cbuffer => {
            if (@TypeOf(value) != u64) return;

            config.cbuffer = value;
        },
        .whitelist => {
            if (@TypeOf(value) != std.ArrayList(std.net.Address)) return;

            const old_whitelist = config.whitelist;
            defer old_whitelist.deinit();

            config.whitelist = value;
        },
    }
}
