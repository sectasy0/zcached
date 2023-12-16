const std = @import("std");

const FILENAME: []const u8 = "zcached.conf";

pub const Config = struct {
    address: std.net.Address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 7556),

    max_connections: u16 = 512,
    max_memory: u32 = 0, // 0 means unlimited, value in Megabytes

    _arena: std.heap.ArenaAllocator,

    pub fn deinit(config: *const Config) void {
        config._arena.deinit();
    }

    pub fn load(allocator: std.mem.Allocator, file_path: ?[]const u8) !Config {
        var config_file_path: []const u8 = FILENAME;
        if (file_path != null) config_file_path = file_path.?;

        var config = Config{ ._arena = std.heap.ArenaAllocator.init(allocator) };

        std.log.info("Loading config from file: {s}", .{config_file_path});

        const file = std.fs.cwd().openFile(config_file_path, .{ .mode = .read_only }) catch |err| {
            // if the file doesn't exist, just return the default config
            if (err == error.FileNotFound) return config;
            return err;
        };
        defer file.close();

        const file_size = (try file.stat()).size;
        var buffer = try config._arena.allocator().alloc(u8, file_size);
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
                var value = try config._arena.allocator().alloc(u8, key_value.items[1].len);
                std.mem.copy(u8, value, key_value.items[1]);

                switch (field.type) {
                    u16 => {
                        const parsed = try std.fmt.parseInt(u16, value, 10);
                        @field(config, field.name) = parsed;
                    },
                    u32 => {
                        const parsed = try std.fmt.parseInt(u32, value, 10);
                        @field(config, field.name) = parsed;
                    },
                    std.net.Address => {
                        const parsed = try std.net.Address.parseIp(value, config.address.getPort());
                        @field(config, field.name) = parsed;
                    },
                    else => unreachable,
                }
            }
        }
    }
};

test "config default values ipv4" {
    var config = try Config.load(std.testing.allocator, null);
    defer config.deinit();

    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 7556);
    try std.testing.expectEqual(config.address.any, address.any);
    try std.testing.expectEqual(config.max_connections, 512);
    try std.testing.expectEqual(config.max_memory, 0);
}

test "config load custom values ipv4" {
    std.fs.cwd().deleteFile("zcached.conf") catch {};

    const file_content = "address=192.168.0.1\nport=1234\nmax_connections=1024\nmax_memory=500\n";
    const file = try std.fs.cwd().createFile(FILENAME, .{});
    try file.writeAll(file_content);
    defer file.close();

    var config = try Config.load(std.testing.allocator, null);
    defer config.deinit();

    const address = std.net.Address.initIp4(.{ 192, 168, 0, 1 }, 1234);
    try std.testing.expectEqual(config.address.any, address.any);
    try std.testing.expectEqual(config.max_connections, 1024);
    try std.testing.expectEqual(config.max_memory, 500);

    try std.fs.cwd().deleteFile(FILENAME);
}

test "config load custom values ipv6" {
    std.fs.cwd().deleteFile("zcached.conf") catch {};

    const file_content = "address=::1\nport=1234\nmax_connections=1024\nmax_memory=500\n";
    const file = try std.fs.cwd().createFile(FILENAME, .{});
    try file.writeAll(file_content);
    defer file.close();

    var config = try Config.load(std.testing.allocator, null);
    defer config.deinit();

    const addr = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    const address = std.net.Address.initIp6(addr, 1234, 0, 0);

    try std.testing.expectEqual(config.address.any, address.any);
    try std.testing.expectEqual(config.max_connections, 1024);
    try std.testing.expectEqual(config.max_memory, 500);

    try std.fs.cwd().deleteFile(FILENAME);
}

test "config load custom values empty port" {
    std.fs.cwd().deleteFile("tmp/zcached_empty_port.conf") catch {};
    std.fs.cwd().deleteDir("tmp") catch {};

    var default_config = Config{ ._arena = std.heap.ArenaAllocator.init(std.testing.allocator) };

    const file_content = "address=::1\nport=\nmax_connections=1024\nmax_memory=500\n";
    try std.fs.cwd().makeDir("tmp");
    const file = try std.fs.cwd().createFile("tmp/zcached_empty_port.conf", .{});
    try file.writeAll(file_content);
    defer file.close();

    var config = try Config.load(std.testing.allocator, "tmp/zcached_empty_port.conf");
    defer config.deinit();

    const addr = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    const address = std.net.Address.initIp6(
        addr,
        default_config.address.getPort(),
        0,
        0,
    );

    try std.testing.expectEqual(address.any, config.address.any);
}
