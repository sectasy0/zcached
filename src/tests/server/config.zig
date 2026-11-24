const std = @import("std");
const Address = @import("../../server/network/address.zig").Address;

const Config = @import("../../server/config.zig");

fn testPath(comptime line: u32) []const u8 {
    return std.fmt.comptimePrint("./tmp/zcached.{d}.conf.zon", .{line});
}

const fixtures = @import("../fixtures.zig");
const ConfigFile = fixtures.ConfigFile;

test "config default values ipv4" {
    var config_file = try ConfigFile.init(testPath(@src().line));
    // try config_file.create(std.testing.allocator);
    defer config_file.deinit();

    var config = try Config.load(std.testing.allocator, config_file.path, null);
    defer config.deinit();

    const address = Address.initIp4(.{ 127, 0, 0, 1 }, 7556);
    try std.testing.expect(config.address.eql(address));
    try std.testing.expectEqual(config.max_clients, 512);
    try std.testing.expectEqual(config.workers, 4);
    try std.testing.expectEqual(config.client_buffer, 4096);
    try std.testing.expect(!config.log_network_payloads);
    try std.testing.expectEqual(config.max_request_size, 10 * 1024 * 1024);
    try std.testing.expectEqual(config.max_memory, 0);
}

test "config can enable network payload logging explicitly" {
    var config_file = try ConfigFile.init(testPath(@src().line));
    const override: []const u8 =
        \\ .{
        \\     .log_network_payloads = true,
        \\ }
    ;

    try config_file.create(std.testing.allocator, override);
    defer config_file.deinit();

    var config = try Config.load(std.testing.allocator, config_file.path, null);
    defer config.deinit();

    try std.testing.expect(config.log_network_payloads);
}

test "TLS config requires server credentials and a CA for client verification" {
    const TLSConfig = Config.TLSConfig;
    const valid_encryption: TLSConfig = .{
        .enabled = true,
        .cert_path = "server-chain.pem",
        .key_path = "server-key.pem",
    };
    try valid_encryption.validate();

    const invalid_configs = [_]TLSConfig{
        .{ .enabled = true },
        .{ .enabled = true, .cert_path = "", .key_path = "server-key.pem" },
        .{ .enabled = true, .cert_path = "server-chain.pem", .key_path = "server-key.pem", .verify_mode = .peer },
        .{ .enabled = true, .cert_path = "server-chain.pem", .key_path = "server-key.pem", .verify_mode = .fail_if_no_peer_cert },
        .{ .enabled = true, .cert_path = "server-chain.pem", .key_path = "server-key.pem", .ca_path = "" },
    };
    for (invalid_configs) |config| {
        try std.testing.expectError(error.InvalidTLSConfig, config.validate());
    }

    const mutual_tls: TLSConfig = .{
        .enabled = true,
        .cert_path = "server-chain.pem",
        .key_path = "server-key.pem",
        .ca_path = "client-ca.pem",
        .verify_mode = .fail_if_no_peer_cert,
    };
    try mutual_tls.validate();
}

test "config loads memory sharding settings alongside legacy memory limit" {
    var config_file = try ConfigFile.init(testPath(@src().line));
    defer config_file.deinit();
    try config_file.create(std.testing.allocator,
        \\.{
        \\    .max_memory = 4096,
        \\    .memory = .{ .shard_count = 3, .default_capacity = 8, .limit = 8192 },
        \\}
    );
    var config = try Config.load(std.testing.allocator, config_file.path, null);
    defer config.deinit();
    try std.testing.expectEqual(@as(usize, 3), config.memory.shard_count);
    try std.testing.expectEqual(@as(usize, 8), config.memory.default_capacity);
    try std.testing.expectEqual(@as(usize, 8192), config.memory.limit);
    try std.testing.expectEqual(@as(usize, 4096), config.max_memory);
}

test "config loads typed network, snapshot and logging sections" {
    var file = try ConfigFile.init(testPath(@src().line));
    defer file.deinit();
    const allocator = std.testing.allocator;
    try file.create(allocator,
        \\.{
        \\    .network = .{ .idle_timeout_ms = 30000, .request_timeout_ms = 5000, .max_pending_response_bytes = 65536 },
        \\    .snapshot = .{ .path = "./tmp/snapshots", .interval_secs = 60, .keep_last = 3 },
        \\    .log = .{ .level = .@"error" },
        \\}
    );
    var config = try Config.load(allocator, file.path, null);
    defer config.deinit();
    try std.testing.expectEqual(@as(u32, 30000), config.network.idle_timeout_ms);
    try std.testing.expectEqual(@as(u32, 5000), config.network.request_timeout_ms);
    try std.testing.expectEqual(@as(usize, 65536), config.network.max_pending_response_bytes);
    try std.testing.expectEqualStrings("./tmp/snapshots", config.snapshot.path.?);
    try std.testing.expectEqual(@as(u32, 60), config.snapshot.interval_secs);
    try std.testing.expectEqual(@as(usize, 3), config.snapshot.keep_last);
    try std.testing.expectEqual(.@"error", config.log.level);
}

test "config rejects invalid operational settings" {
    var file = try ConfigFile.init(testPath(@src().line));
    defer file.deinit();
    const allocator = std.testing.allocator;
    for ([_]struct { source: []const u8, failure: anyerror }{
        .{ .source = ".{ .network = .{ .request_timeout_ms = -1 } }", .failure = error.ParseZon },
        .{ .source = ".{ .network = .{ .idle_timeout_ms = 4294967296 } }", .failure = error.ParseZon },
        .{ .source = ".{ .snapshot = .{ .path = \"\" } }", .failure = error.InvalidSnapshotPath },
        .{ .source = ".{ .snapshot = .{ .path = \"./persist\" }, .log = .{ .level = .verbose } }", .failure = error.ParseZon },
    }) |case| {
        try file.create(allocator, case.source);
        const result = Config.load(allocator, file.path, null);
        if (result) |config| config.deinit() else |_| {}
        try std.testing.expectError(case.failure, result);
    }
}

test "config load custom values ipv4" {
    var config_file = try ConfigFile.init(testPath(@src().line));
    config_file.address = "192.168.0.1";
    config_file.port = "1234";
    config_file.max_clients = "1024";
    config_file.max_memory = "500";
    config_file.client_buffer = "8192";

    try config_file.create(std.testing.allocator, null);
    defer config_file.deinit();

    var config = try Config.load(std.testing.allocator, config_file.path, null);
    defer config.deinit();

    const address = Address.initIp4(.{ 192, 168, 0, 1 }, 1234);
    try std.testing.expect(config.address.eql(address));
    try std.testing.expectEqual(config.max_clients, 1024);
    try std.testing.expectEqual(config.workers, 4);
    try std.testing.expectEqual(config.client_buffer, 8192);
    try std.testing.expectEqual(config.max_request_size, 10 * 1024 * 1024);
    try std.testing.expectEqual(config.max_memory, 500);
}

test "config load custom values ipv6" {
    var config_file = try ConfigFile.init(testPath(@src().line));
    config_file.address = "1fa7:68c4:a912:a3a7:f882:706d:15eb:1fd1";
    config_file.port = "1234";
    config_file.max_clients = "1024";
    config_file.workers = "12";
    config_file.max_memory = "500";

    try config_file.create(std.testing.allocator, null);
    defer config_file.deinit();

    var config = try Config.load(std.testing.allocator, config_file.path, null);
    defer config.deinit();

    const addr: [16]u8 = .{
        0x1f, 0xa7, 0x68, 0xc4,
        0xa9, 0x12, 0xa3, 0xa7,
        0xf8, 0x82, 0x70, 0x6d,
        0x15, 0xeb, 0x1f, 0xd1,
    };
    const address = Address.initIp6(addr, 1234, 0, 0);

    try std.testing.expect(config.address.eql(address));
    try std.testing.expectEqual(config.max_clients, 1024);
    try std.testing.expectEqual(config.workers, 12);
    try std.testing.expectEqual(config.client_buffer, 4096);
    try std.testing.expectEqual(config.max_request_size, 10 * 1024 * 1024);
    try std.testing.expectEqual(config.max_memory, 500);
}

test "config load custom values empty port" {
    var config_file = try ConfigFile.init(testPath(@src().line));
    config_file.address = "1fa7:68c4:a912:a3a7:f882:706d:15eb:1fd1";
    // in case there is empty port or another integer value
    // parsing will fail and default values will be loaded.
    config_file.port = "";

    try config_file.create(std.testing.allocator, null);
    defer config_file.deinit();

    var config = try Config.load(std.testing.allocator, config_file.path, null);
    defer config.deinit();

    const address = Address.initIp4(.{ 127, 0, 0, 1 }, 7556);

    try std.testing.expect(config.address.eql(address));
    try std.testing.expectEqual(config.address.getPort(), 7556); // default
    try std.testing.expectEqual(config.workers, 4);
    try std.testing.expectEqual(config.client_buffer, 4096);
    try std.testing.expectEqual(config.max_request_size, 10 * 1024 * 1024);
    try std.testing.expectEqual(config.max_memory, 0);
}

test "config load custom values empty address" {
    var config_file = try ConfigFile.init(testPath(@src().line));
    // address will be ignored and port will be loaded
    config_file.address = "";
    config_file.port = "1234";

    try config_file.create(std.testing.allocator, null);
    defer config_file.deinit();

    var config = try Config.load(std.testing.allocator, config_file.path, null);
    defer config.deinit();

    const address = Address.initIp4(.{ 127, 0, 0, 1 }, 1234);

    try std.testing.expect(config.address.eql(address));
    try std.testing.expectEqual(config.address.getPort(), 1234); // default
    try std.testing.expectEqual(config.workers, 4);
    try std.testing.expectEqual(config.client_buffer, 4096);
    try std.testing.expectEqual(config.max_request_size, 10 * 1024 * 1024);
    try std.testing.expectEqual(config.max_memory, 0);
}

test "config load custom values empty workers" {
    var config_file = try ConfigFile.init(testPath(@src().line));
    config_file.address = "1fa7:68c4:a912:a3a7:f882:706d:15eb:1fd1";
    // in case there is empty port or another integer value
    // parsing will fail and default values will be loaded.
    config_file.workers = "";

    try config_file.create(std.testing.allocator, null);
    defer config_file.deinit();

    var config = try Config.load(std.testing.allocator, config_file.path, null);
    defer config.deinit();

    const address = Address.initIp4(.{ 127, 0, 0, 1 }, 7556);

    try std.testing.expect(config.address.eql(address));
    try std.testing.expectEqual(config.address.getPort(), 7556); // default
    try std.testing.expectEqual(config.workers, 4);
    try std.testing.expectEqual(config.client_buffer, 4096);
    try std.testing.expectEqual(config.max_request_size, 10 * 1024 * 1024);
    try std.testing.expectEqual(config.max_memory, 0);
}

test "config load custom values whitelist" {
    // we alerady have set whitelist in ConfigFile
    var config_file = try ConfigFile.init(testPath(@src().line));
    try config_file.create(std.testing.allocator, null);
    defer config_file.deinit();

    var config = try Config.load(std.testing.allocator, config_file.path, null);
    defer config.deinit();

    const address = Address.initIp4(.{ 127, 0, 0, 1 }, 7556);
    try std.testing.expect(config.address.eql(address));
    try std.testing.expectEqual(config.max_clients, 512);
    try std.testing.expectEqual(config.workers, 4);
    try std.testing.expectEqual(config.client_buffer, 4096);
    try std.testing.expectEqual(config.max_request_size, 10 * 1024 * 1024);
    try std.testing.expectEqual(config.max_memory, 0);

    var whitelist = std.array_list.Managed(Address).init(std.testing.allocator);
    defer whitelist.deinit();

    try whitelist.append(Address.initIp4(.{ 127, 0, 0, 1 }, 7556));
    try whitelist.append(Address.initIp4(.{ 127, 0, 0, 2 }, 7556));
    try whitelist.append(Address.initIp4(.{ 127, 0, 0, 3 }, 7556));
    try whitelist.append(Address.initIp4(.{ 127, 0, 0, 4 }, 7556));

    try std.testing.expectEqual(config.whitelist.items.len, 4);
}

test "config load custom values empty whitelist" {
    // we alerady have set whitelist in ConfigFile
    var config_file = try ConfigFile.init(testPath(@src().line));

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

    var config = try Config.load(std.testing.allocator, config_file.path, null);
    defer config.deinit();

    const address = Address.initIp4(.{ 127, 0, 0, 8 }, 7556);
    try std.testing.expect(config.address.eql(address));
    try std.testing.expectEqual(config.max_clients, 512);
    try std.testing.expectEqual(config.workers, 12);
    try std.testing.expectEqual(config.client_buffer, 1024);
    try std.testing.expectEqual(config.max_request_size, 0);
    try std.testing.expectEqual(config.max_memory, 0);

    try std.testing.expectEqual(config.whitelist.items.len, 0);
}

test "config load custom values empty whitelist string in zon" {
    var config_file = try ConfigFile.init(testPath(@src().line));

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

    var config = try Config.load(std.testing.allocator, config_file.path, null);
    defer config.deinit();

    const address = Address.initIp4(.{ 127, 0, 0, 8 }, 7556);
    try std.testing.expect(config.address.eql(address));
    try std.testing.expectEqual(config.max_clients, 512);
    try std.testing.expectEqual(config.workers, 12);
    try std.testing.expectEqual(config.client_buffer, 1024);
    try std.testing.expectEqual(config.max_request_size, 0);
    try std.testing.expectEqual(config.max_memory, 0);

    try std.testing.expectEqual(config.whitelist.items.len, 0);
}

test "config load custom values empty whitelist int in zon" {
    // we alerady have set whitelist in ConfigFile
    var config_file = try ConfigFile.init(testPath(@src().line));

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

    var config = try Config.load(std.testing.allocator, config_file.path, null);
    defer config.deinit();

    const address = Address.initIp4(.{ 127, 0, 0, 8 }, 7556);
    try std.testing.expect(config.address.eql(address));
    try std.testing.expectEqual(config.max_clients, 512);
    try std.testing.expectEqual(config.workers, 12);
    try std.testing.expectEqual(config.client_buffer, 1024);
    try std.testing.expectEqual(config.max_request_size, 0);
    try std.testing.expectEqual(config.max_memory, 0);

    try std.testing.expectEqual(config.whitelist.items.len, 0);
}

test "config load custom values only root" {
    var config_file = try ConfigFile.init(testPath(@src().line));

    const override: []const u8 = ".{}";

    try config_file.create(std.testing.allocator, override);
    defer config_file.deinit();

    var config = try Config.load(std.testing.allocator, config_file.path, null);
    defer config.deinit();

    const address = Address.initIp4(.{ 127, 0, 0, 1 }, 7556);
    try std.testing.expect(config.address.eql(address));
    try std.testing.expectEqual(config.max_clients, 512);
    try std.testing.expectEqual(config.workers, 4);
    try std.testing.expectEqual(config.client_buffer, 4096);
    try std.testing.expectEqual(config.max_request_size, 10 * 1024 * 1024);
    try std.testing.expectEqual(config.max_memory, 0);

    try std.testing.expectEqual(config.whitelist.items.len, 0);
}

test "config load custom values empty file" {
    var config_file = try ConfigFile.init(testPath(@src().line));

    const override: []const u8 = "";

    try config_file.create(std.testing.allocator, override);
    defer config_file.deinit();

    var config = try Config.load(std.testing.allocator, config_file.path, null);
    defer config.deinit();

    const address = Address.initIp4(.{ 127, 0, 0, 1 }, 7556);
    try std.testing.expect(config.address.eql(address));
    try std.testing.expectEqual(config.max_clients, 512);
    try std.testing.expectEqual(config.workers, 4);
    try std.testing.expectEqual(config.client_buffer, 4096);
    try std.testing.expectEqual(config.max_request_size, 10 * 1024 * 1024);
    try std.testing.expectEqual(config.max_memory, 0);

    try std.testing.expectEqual(config.whitelist.items.len, 0);
}

test "config load custom values missing some fields" {
    // we alerady have set whitelist in ConfigFile
    var config_file = try ConfigFile.init(testPath(@src().line));

    const override: []const u8 =
        \\ .{{
        \\     .address = "127.0.0.8",
        \\     .port = 7556,
        \\     .whitelist = .{},
        \\ }}
    ;

    try config_file.create(std.testing.allocator, override);
    defer config_file.deinit();

    var config = try Config.load(std.testing.allocator, config_file.path, null);
    defer config.deinit();

    const address = Address.initIp4(.{ 127, 0, 0, 1 }, 7556);
    try std.testing.expect(config.address.eql(address));
    try std.testing.expectEqual(config.max_clients, 512);
    try std.testing.expectEqual(config.workers, 4);
    try std.testing.expectEqual(config.client_buffer, 4096);
    try std.testing.expectEqual(config.max_request_size, 10 * 1024 * 1024);
    try std.testing.expectEqual(config.max_memory, 0);

    try std.testing.expectEqual(config.whitelist.items.len, 0);
}

test "config loads AOF strategy path and rewrite thresholds" {
    var config_file = try ConfigFile.init(testPath(@src().line));

    const override: []const u8 =
        \\ .{
        \\     .aof = .{
        \\         .flush_strategy = .auto,
        \\         .path = "./tmp/test-appendonly.aof",
        \\         .rewrite_percentage = 50,
        \\         .rewrite_min_size = 1024,
        \\     },
        \\ }
    ;

    try config_file.create(std.testing.allocator, override);
    defer config_file.deinit();

    var config = try Config.load(std.testing.allocator, config_file.path, null);
    defer config.deinit();

    try std.testing.expectEqual(Config.AOFConfig.FlushStrategy.auto, config.aof.flush_strategy);
    try std.testing.expectEqualStrings("./tmp/test-appendonly.aof", config.aof.path.?);
    try std.testing.expectEqual(@as(u32, 50), config.aof.rewrite_percentage);
    try std.testing.expectEqual(@as(usize, 1024), config.aof.rewrite_min_size);
}
