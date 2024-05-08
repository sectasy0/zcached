const std = @import("std");

const Config = @import("../../server/config.zig");
const DEFAULT_PATH = @import("../../server/config.zig").DEFAULT_PATH;

test "config default values ipv4" {
    var config = try Config.load(std.testing.allocator, null, null);
    defer config.deinit();

    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 7556);
    try std.testing.expectEqual(config.address.any, address.any);
    try std.testing.expectEqual(config.maxclients, 512);
    try std.testing.expectEqual(config.maxmemory, 0);

    std.fs.cwd().deleteFile(DEFAULT_PATH) catch {};
}

test "config load custom values ipv4" {
    std.fs.cwd().deleteFile(DEFAULT_PATH) catch {};

    const file_content = "address=192.168.0.1\nport=1234\nmaxclients=1024\nmaxmemory=500\n";
    const file = try std.fs.cwd().createFile(DEFAULT_PATH, .{});
    try file.writeAll(file_content);
    defer file.close();

    var config = try Config.load(std.testing.allocator, null, null);
    defer config.deinit();

    const address = std.net.Address.initIp4(.{ 192, 168, 0, 1 }, 1234);
    try std.testing.expectEqual(config.address.any, address.any);
    try std.testing.expectEqual(config.maxclients, 1024);
    try std.testing.expectEqual(config.maxmemory, 500);

    try std.fs.cwd().deleteFile(DEFAULT_PATH);
}

test "config load custom values ipv6" {
    std.fs.cwd().deleteFile(DEFAULT_PATH) catch {};

    const file_content = "address=::1\nport=1234\nmaxclients=1024\nmaxmemory=500\n";
    const file = try std.fs.cwd().createFile(DEFAULT_PATH, .{});
    try file.writeAll(file_content);
    defer file.close();

    var config = try Config.load(std.testing.allocator, null, null);
    defer config.deinit();

    const addr = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    const address = std.net.Address.initIp6(addr, 1234, 0, 0);

    try std.testing.expectEqual(config.address.any, address.any);
    try std.testing.expectEqual(config.maxclients, 1024);
    try std.testing.expectEqual(config.maxmemory, 500);

    try std.fs.cwd().deleteFile(DEFAULT_PATH);
}

test "config load custom values empty port" {
    std.fs.cwd().deleteFile("./tmp/zcached_empty_port.conf") catch {};
    std.fs.cwd().deleteDir("tmp") catch {};

    const file_content = "address=::1\nport=\nmaxclients=1024\nmaxmemory=500\n";
    std.fs.cwd().makeDir("tmp") catch {};
    const file = try std.fs.cwd().createFile("./tmp/zcached_empty_port.conf", .{});
    try file.writeAll(file_content);
    defer file.close();

    var default_config = Config{ ._arena = std.heap.ArenaAllocator.init(std.testing.allocator) };

    var config = try Config.load(std.testing.allocator, "./tmp/zcached_empty_port.conf", null);
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

test "config load custom values empty address" {
    std.fs.cwd().deleteFile("./tmp/zcached_empty_address.conf") catch {};
    std.fs.cwd().deleteDir("tmp") catch {};

    const file_content = "address=\nport=1234\nmaxclients=1024\nmaxmemory=500\n";
    std.fs.cwd().makeDir("tmp") catch {};
    const file = try std.fs.cwd().createFile("./tmp/zcached_empty_address.conf", .{});
    try file.writeAll(file_content);
    defer file.close();

    var config = try Config.load(std.testing.allocator, "./tmp/zcached_empty_address.conf", null);
    defer config.deinit();

    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 1234);

    try std.testing.expectEqual(address.any, config.address.any);
}

test "config load custom values workers" {
    std.fs.cwd().deleteFile("./tmp/zcached_thread.conf") catch {};
    std.fs.cwd().deleteDir("tmp") catch {};

    const file_content = "address=::1\nport=1234\nmaxclients=1024\nmaxmemory=500\nworkers=4\n";
    std.fs.cwd().makeDir("tmp") catch {};
    const file = try std.fs.cwd().createFile("./tmp/zcached_thread.conf", .{});
    try file.writeAll(file_content);
    defer file.close();

    var config = try Config.load(std.testing.allocator, "./tmp/zcached_thread.conf", null);
    defer config.deinit();

    try std.testing.expectEqual(config.workers, 4);
}

test "config load custom values empty workers" {
    std.fs.cwd().deleteFile("./tmp/zcached_empty_workers.conf") catch {};
    std.fs.cwd().deleteDir("tmp") catch {};

    const file_content = "address=::1\nport=1234\nmaxclients=1024\nmaxmemory=500\nworkers=\n";
    std.fs.cwd().makeDir("tmp") catch {};
    const file = try std.fs.cwd().createFile("./tmp/zcached_empty_workers.conf", .{});
    try file.writeAll(file_content);
    defer file.close();

    var config = try Config.load(std.testing.allocator, "./tmp/zcached_empty_workers.conf", null);
    defer config.deinit();

    try std.testing.expectEqual(config.workers, 4);
}

test "config load custom values whitelist" {
    std.fs.cwd().deleteFile("./tmp/zcached_whitelist.conf") catch {};
    std.fs.cwd().deleteDir("tmp") catch {};

    const file_content = "address=::1\nport=1234\nmaxclients=1024\nmaxmemory=500\nwhitelist=192.168.0.1,127.0.0.1\n";
    std.fs.cwd().makeDir("tmp") catch {};
    const file = try std.fs.cwd().createFile("./tmp/zcached_whitelist.conf", .{});
    try file.writeAll(file_content);
    defer file.close();

    var config = try Config.load(std.testing.allocator, "./tmp/zcached_whitelist.conf", null);
    defer config.deinit();

    const address = std.net.Address.initIp4(.{ 192, 168, 0, 1 }, config.address.getPort());
    const address_second = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, config.address.getPort());

    try std.testing.expectEqual(config.whitelist.items[0].any, address.any);
    try std.testing.expectEqual(config.whitelist.items[1].any, address_second.any);
}

test "config load custom values empty whitelist" {
    std.fs.cwd().deleteFile("./tmp/zcached_empty_whitelist.conf") catch {};
    std.fs.cwd().deleteDir("tmp") catch {};

    const file_content = "address=::1\nport=1234\nmaxclients=1024\nmaxmemory=500\nwhitelist=\n";
    std.fs.cwd().makeDir("tmp") catch {};
    const file = try std.fs.cwd().createFile("./tmp/zcached_empty_whitelist.conf", .{});
    try file.writeAll(file_content);
    defer file.close();

    var config = try Config.load(std.testing.allocator, "./tmp/zcached_empty_whitelist.conf", null);
    defer config.deinit();

    try std.testing.expectEqual(config.whitelist.items.len, 0);
}

test "config load custom values invalid whitelist delimiter" {
    std.fs.cwd().deleteFile("./tmp/zcached_empty_whitelist.conf") catch {};
    std.fs.cwd().deleteDir("tmp") catch {};

    const file_content = "address=::1\nport=1234\nmaxclients=1024\nmaxmemory=500\nwhitelist=192.168.0.1;127.0.0.1\n";
    std.fs.cwd().makeDir("tmp") catch {};
    const file = try std.fs.cwd().createFile("./tmp/zcached_empty_whitelist.conf", .{});
    try file.writeAll(file_content);
    defer file.close();

    var config = try Config.load(std.testing.allocator, "./tmp/zcached_empty_whitelist.conf", null);
    defer config.deinit();

    try std.testing.expectEqual(config.whitelist.items.len, 0);
}

test "config load proto_max_bulk_len" {
    std.fs.cwd().deleteFile("./tmp/zcached_proto_max_bulk_len.conf") catch {};
    std.fs.cwd().deleteDir("tmp") catch {};

    const file_content = "address=::1\nport=1234\nmaxclients=1024\nmaxmemory=500\nproto_max_bulk_len=1024\n";
    std.fs.cwd().makeDir("tmp") catch {};
    const file = try std.fs.cwd().createFile("./tmp/zcached_proto_max_bulk_len.conf", .{});
    try file.writeAll(file_content);
    defer file.close();

    var config = try Config.load(std.testing.allocator, "./tmp/zcached_proto_max_bulk_len.conf", null);
    defer config.deinit();

    try std.testing.expectEqual(config.proto_max_bulk_len, 1024);
}
