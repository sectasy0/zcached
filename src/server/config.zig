const std = @import("std");
const utils = @import("utils.zig");

pub const DEFAULT_PATH: []const u8 = "./zcached.conf";

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

_arena: std.heap.ArenaAllocator,

pub fn deinit(config: *const Config) void {
    config._arena.deinit();
}

pub fn load(allocator: std.mem.Allocator, file_path: ?[]const u8, log_path: ?[]const u8) !Config {
    var path: []const u8 = DEFAULT_PATH;
    if (file_path != null) path = file_path.?;

    var config = Config{ ._arena = std.heap.ArenaAllocator.init(allocator) };
    if (log_path != null) config.loger_path = log_path.?;

    var timestamp: [40]u8 = undefined;
    const t_size = utils.timestampf(&timestamp);

    config.whitelist = std.ArrayList(std.net.Address).init(allocator);

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
    const buffer = try config._arena.allocator().alloc(u8, file_size);
    defer config._arena.allocator().free(buffer);

    const readed_size = try file.read(buffer);
    if (readed_size != file_size) return error.InvalidInput;

    var iter = std.mem.split(u8, buffer, "\n");
    while (iter.next()) |line| {
        // # is comment, _ is for internal use, like _arena
        if (line.len == 0 or line[0] == '#' or line[0] == '_') continue;

        const key_value = try process_line(config._arena.allocator(), line);
        defer key_value.deinit();

        // Special case for address port because `std.net.Address` is struct with address and port
        if (std.mem.eql(u8, key_value.items[0], "port")) {
            if (key_value.items[1].len == 0) continue;

            const parsed = try std.fmt.parseInt(u16, key_value.items[1], 10);
            config.address.setPort(parsed);
            continue;
        }

        try assign_field_value(&config, key_value);
    }

    return config;
}

fn process_line(allocator: std.mem.Allocator, line: []const u8) !std.ArrayList([]const u8) {
    var result = std.ArrayList([]const u8).init(allocator);

    var iter = std.mem.split(u8, line, "=");

    const key = iter.next();
    const value = iter.next();

    if (key == null or value == null) return error.InvalidInput;

    try result.append(key.?);
    try result.append(value.?);

    return result;
}

fn assign_field_value(config: *Config, key_value: std.ArrayList([]const u8)) !void {
    // I don't like how many nested things are here, but there is no other way
    inline for (std.meta.fields(Config)) |field| {
        if (std.mem.eql(u8, field.name, key_value.items[0])) {
            const value = config._arena.allocator().alloc(u8, key_value.items[1].len) catch |err| {
                std.debug.print(
                    "ERROR [{d}] * failed to allocate memory {?}\n",
                    .{ std.time.timestamp(), err },
                );
                return;
            };

            @memcpy(value, key_value.items[1]);

            if (value.len == 0) return;

            switch (field.type) {
                usize => {
                    const parsed = std.fmt.parseInt(usize, value, 10) catch |err| {
                        std.debug.print(
                            "DEBUG [{d}] * parsing {s} as usize, {?}\n",
                            .{ std.time.timestamp(), value, err },
                        );
                        return;
                    };
                    @field(config, field.name) = parsed;
                },
                std.net.Address => {
                    const parsed = std.net.Address.parseIp(value, config.address.getPort()) catch |err| {
                        std.debug.print(
                            "DEBUG [{d}] * parsing {s} as std.net.Address, {?}\n",
                            .{ std.time.timestamp(), value, err },
                        );
                        return;
                    };
                    @field(config, field.name) = parsed;
                },
                std.ArrayList(std.net.Address) => {
                    config.whitelist = std.ArrayList(std.net.Address).init(config._arena.allocator());

                    var addresses = std.mem.split(u8, value, ",");

                    while (addresses.next()) |address| {
                        const parsed = std.net.Address.parseIp(address, config.address.getPort()) catch |err| {
                            std.debug.print(
                                "DEBUG [{d}] * parsing {s} as std.net.Address, {?}\n",
                                .{ std.time.timestamp(), address, err },
                            );
                            return;
                        };
                        try @field(config, field.name).append(parsed);
                    }
                },
                else => unreachable,
            }
        }
    }
}
