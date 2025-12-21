const std = @import("std");

const Config = @import("../../server/config.zig");
const DEFAULT_PATH = "./tmp/zcached.conf.zon";

const fixtures = @import("../fixtures.zig");
const ConfigFile = fixtures.ConfigFile;

test "config default values ipv4" {
    var config_file = try ConfigFile.init(DEFAULT_PATH);
    // try config_file.create(std.testing.allocator);
    defer config_file.deinit();

    var config = try Config.load(std.testing.allocator, DEFAULT_PATH, null);
    defer config.deinit();

    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 7556);
    try std.testing.expectEqual(config.address.any, address.any);
    try std.testing.expectEqual(config.max_clients, 512);
    try std.testing.expectEqual(config.workers, 4);
    try std.testing.expectEqual(config.client_buffer, 4096);
    try std.testing.expectEqual(config.max_request_size, 10 * 1024 * 1024);
    try std.testing.expectEqual(config.max_memory, 0);
}

test "config load custom values ipv4" {
    var config_file = try ConfigFile.init(DEFAULT_PATH);
    config_file.address = "192.168.0.1";
    config_file.port = "1234";
    config_file.max_clients = "1024";
    config_file.max_memory = "500";
    config_file.client_buffer = "8192";

    try config_file.create(std.testing.allocator, null);
    defer config_file.deinit();

    var config = try Config.load(std.testing.allocator, DEFAULT_PATH, null);
    defer config.deinit();

    const address = std.net.Address.initIp4(.{ 192, 168, 0, 1 }, 1234);
    try std.testing.expectEqual(config.address.any, address.any);
    try std.testing.expectEqual(config.max_clients, 1024);
    try std.testing.expectEqual(config.workers, 4);
    try std.testing.expectEqual(config.client_buffer, 8192);
    try std.testing.expectEqual(config.max_request_size, 10 * 1024 * 1024);
    try std.testing.expectEqual(config.max_memory, 500);
}

test "config load custom values ipv6" {
    var config_file = try ConfigFile.init(DEFAULT_PATH);
    config_file.address = "1fa7:68c4:a912:a3a7:f882:706d:15eb:1fd1";
    config_file.port = "1234";
    config_file.max_clients = "1024";
    config_file.workers = "12";
    config_file.max_memory = "500";

    try config_file.create(std.testing.allocator, null);
    defer config_file.deinit();

    var config = try Config.load(std.testing.allocator, DEFAULT_PATH, null);
    defer config.deinit();

    const addr: [16]u8 = .{
        0x1f, 0xa7, 0x68, 0xc4,
        0xa9, 0x12, 0xa3, 0xa7,
        0xf8, 0x82, 0x70, 0x6d,
        0x15, 0xeb, 0x1f, 0xd1,
    };
    const address = std.net.Address.initIp6(addr, 1234, 0, 0);

    try std.testing.expectEqual(config.address.any, address.any);
    try std.testing.expectEqual(config.max_clients, 1024);
    try std.testing.expectEqual(config.workers, 12);
    try std.testing.expectEqual(config.client_buffer, 4096);
    try std.testing.expectEqual(config.max_request_size, 10 * 1024 * 1024);
    try std.testing.expectEqual(config.max_memory, 500);
}

test "config load custom values empty port" {
    var config_file = try ConfigFile.init(DEFAULT_PATH);
    config_file.address = "1fa7:68c4:a912:a3a7:f882:706d:15eb:1fd1";
    // in case there is empty port or another integer value
    // parsing will fail and default values will be loaded.
    config_file.port = "";

    try config_file.create(std.testing.allocator, null);
    defer config_file.deinit();

    var config = try Config.load(std.testing.allocator, DEFAULT_PATH, null);
    defer config.deinit();

    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 7556);

    try std.testing.expectEqual(config.address.any, address.any);
    try std.testing.expectEqual(config.address.getPort(), 7556); // default
    try std.testing.expectEqual(config.workers, 4);
    try std.testing.expectEqual(config.client_buffer, 4096);
    try std.testing.expectEqual(config.max_request_size, 10 * 1024 * 1024);
    try std.testing.expectEqual(config.max_memory, 0);
}

test "config load custom values empty address" {
    var config_file = try ConfigFile.init(DEFAULT_PATH);
    // address will be ignored and port will be loaded
    config_file.address = "";
    config_file.port = "1234";

    try config_file.create(std.testing.allocator, null);
    defer config_file.deinit();

    var config = try Config.load(std.testing.allocator, DEFAULT_PATH, null);
    defer config.deinit();

    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 1234);

    try std.testing.expectEqual(config.address.any, address.any);
    try std.testing.expectEqual(config.address.getPort(), 1234); // default
    try std.testing.expectEqual(config.workers, 4);
    try std.testing.expectEqual(config.client_buffer, 4096);
    try std.testing.expectEqual(config.max_request_size, 10 * 1024 * 1024);
    try std.testing.expectEqual(config.max_memory, 0);
}

test "config load custom values empty workers" {
    var config_file = try ConfigFile.init(DEFAULT_PATH);
    config_file.address = "1fa7:68c4:a912:a3a7:f882:706d:15eb:1fd1";
    // in case there is empty port or another integer value
    // parsing will fail and default values will be loaded.
    config_file.workers = "";

    try config_file.create(std.testing.allocator, null);
    defer config_file.deinit();

    var config = try Config.load(std.testing.allocator, DEFAULT_PATH, null);
    defer config.deinit();

    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 7556);

    try std.testing.expectEqual(config.address.any, address.any);
    try std.testing.expectEqual(config.address.getPort(), 7556); // default
    try std.testing.expectEqual(config.workers, 4);
    try std.testing.expectEqual(config.client_buffer, 4096);
    try std.testing.expectEqual(config.max_request_size, 10 * 1024 * 1024);
    try std.testing.expectEqual(config.max_memory, 0);
}

test "config load custom values whitelist" {
    // we alerady have set whitelist in ConfigFile
    var config_file = try ConfigFile.init(DEFAULT_PATH);
    try config_file.create(std.testing.allocator, null);
    defer config_file.deinit();

    var config = try Config.load(std.testing.allocator, DEFAULT_PATH, null);
    defer config.deinit();

    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 7556);
    try std.testing.expectEqual(config.address.any, address.any);
    try std.testing.expectEqual(config.max_clients, 512);
    try std.testing.expectEqual(config.workers, 4);
    try std.testing.expectEqual(config.client_buffer, 4096);
    try std.testing.expectEqual(config.max_request_size, 10 * 1024 * 1024);
    try std.testing.expectEqual(config.max_memory, 0);

    var whitelist = std.array_list.Managed(std.net.Address).init(std.testing.allocator);
    defer whitelist.deinit();

    try whitelist.append(std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 7556));
    try whitelist.append(std.net.Address.initIp4(.{ 127, 0, 0, 2 }, 7556));
    try whitelist.append(std.net.Address.initIp4(.{ 127, 0, 0, 3 }, 7556));
    try whitelist.append(std.net.Address.initIp4(.{ 127, 0, 0, 4 }, 7556));

    try std.testing.expectEqual(config.whitelist.items.len, 4);
}

test "config load custom values empty whitelist" {
    // we alerady have set whitelist in ConfigFile
    var config_file = try ConfigFile.init(DEFAULT_PATH);

    const override: []const u8 =
        \\ .{
        \\     .address = "127.0.0.8",
        \\     .port = 7556,
        \\     .max_clients = 512,
        \\     .max_memory = 0,
        \\     .max_request_size = 0,
        \\     .workers = 12,
        \\     .client_buffer = 1024,
        \\     .whitelist = .{}
        \\ }
    ;

    try config_file.create(std.testing.allocator, override);
    defer config_file.deinit();

    var config = try Config.load(std.testing.allocator, DEFAULT_PATH, null);
    defer config.deinit();

    const address = std.net.Address.initIp4(.{ 127, 0, 0, 8 }, 7556);
    try std.testing.expectEqual(config.address.any, address.any);
    try std.testing.expectEqual(config.max_clients, 512);
    try std.testing.expectEqual(config.workers, 12);
    try std.testing.expectEqual(config.client_buffer, 1024);
    try std.testing.expectEqual(config.max_request_size, 0);
    try std.testing.expectEqual(config.max_memory, 0);

    try std.testing.expectEqual(config.whitelist.items.len, 0);
}

test "config load custom values empty whitelist string in zon" {
    var config_file = try ConfigFile.init(DEFAULT_PATH);

    const override: []const u8 =
        \\ .{
        \\     .address = "127.0.0.8",
        \\     .port = 7556,
        \\     .max_clients = 512,
        \\     .max_memory = 0,
        \\     .max_request_size = 0,
        \\     .workers = 12,
        \\     .client_buffer = 1024,
        \\     .whitelist = "",
        \\ }
    ;

    try config_file.create(std.testing.allocator, override);
    defer config_file.deinit();

    var config = try Config.load(std.testing.allocator, DEFAULT_PATH, null);
    defer config.deinit();

    const address = std.net.Address.initIp4(.{ 127, 0, 0, 8 }, 7556);
    try std.testing.expectEqual(config.address.any, address.any);
    try std.testing.expectEqual(config.max_clients, 512);
    try std.testing.expectEqual(config.workers, 12);
    try std.testing.expectEqual(config.client_buffer, 1024);
    try std.testing.expectEqual(config.max_request_size, 0);
    try std.testing.expectEqual(config.max_memory, 0);

    try std.testing.expectEqual(config.whitelist.items.len, 0);
}

test "config load custom values empty whitelist int in zon" {
    // we alerady have set whitelist in ConfigFile
    var config_file = try ConfigFile.init(DEFAULT_PATH);

    const override: []const u8 =
        \\ .{
        \\     .address = "127.0.0.8",
        \\     .port = 7556,
        \\     .max_clients = 512,
        \\     .max_memory = 0,
        \\     .max_request_size = 0,
        \\     .workers = 12,
        \\     .client_buffer = 1024,
        \\     .whitelist = 0,
        \\ }
    ;

    try config_file.create(std.testing.allocator, override);
    defer config_file.deinit();

    var config = try Config.load(std.testing.allocator, DEFAULT_PATH, null);
    defer config.deinit();

    const address = std.net.Address.initIp4(.{ 127, 0, 0, 8 }, 7556);
    try std.testing.expectEqual(config.address.any, address.any);
    try std.testing.expectEqual(config.max_clients, 512);
    try std.testing.expectEqual(config.workers, 12);
    try std.testing.expectEqual(config.client_buffer, 1024);
    try std.testing.expectEqual(config.max_request_size, 0);
    try std.testing.expectEqual(config.max_memory, 0);

    try std.testing.expectEqual(config.whitelist.items.len, 0);
}

test "config load custom values only root" {
    var config_file = try ConfigFile.init(DEFAULT_PATH);

    const override: []const u8 = ".{}";

    try config_file.create(std.testing.allocator, override);
    defer config_file.deinit();

    var config = try Config.load(std.testing.allocator, DEFAULT_PATH, null);
    defer config.deinit();

    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 7556);
    try std.testing.expectEqual(config.address.any, address.any);
    try std.testing.expectEqual(config.max_clients, 512);
    try std.testing.expectEqual(config.workers, 4);
    try std.testing.expectEqual(config.client_buffer, 4096);
    try std.testing.expectEqual(config.max_request_size, 10 * 1024 * 1024);
    try std.testing.expectEqual(config.max_memory, 0);

    try std.testing.expectEqual(config.whitelist.items.len, 0);
}

test "config load custom values empty file" {
    var config_file = try ConfigFile.init(DEFAULT_PATH);

    const override: []const u8 = "";

    try config_file.create(std.testing.allocator, override);
    defer config_file.deinit();

    var config = try Config.load(std.testing.allocator, DEFAULT_PATH, null);
    defer config.deinit();

    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 7556);
    try std.testing.expectEqual(config.address.any, address.any);
    try std.testing.expectEqual(config.max_clients, 512);
    try std.testing.expectEqual(config.workers, 4);
    try std.testing.expectEqual(config.client_buffer, 4096);
    try std.testing.expectEqual(config.max_request_size, 10 * 1024 * 1024);
    try std.testing.expectEqual(config.max_memory, 0);

    try std.testing.expectEqual(config.whitelist.items.len, 0);
}

test "config load custom values missing some fields" {
    // we alerady have set whitelist in ConfigFile
    var config_file = try ConfigFile.init(DEFAULT_PATH);

    const override: []const u8 =
        \\ .{{
        \\     .address = "127.0.0.8",
        \\     .port = 7556,
        \\     .whitelist = .{},
        \\ }}
    ;

    try config_file.create(std.testing.allocator, override);
    defer config_file.deinit();

    var config = try Config.load(std.testing.allocator, DEFAULT_PATH, null);
    defer config.deinit();

    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 7556);
    try std.testing.expectEqual(config.address.any, address.any);
    try std.testing.expectEqual(config.max_clients, 512);
    try std.testing.expectEqual(config.workers, 4);
    try std.testing.expectEqual(config.client_buffer, 4096);
    try std.testing.expectEqual(config.max_request_size, 10 * 1024 * 1024);
    try std.testing.expectEqual(config.max_memory, 0);

    try std.testing.expectEqual(config.whitelist.items.len, 0);
}
