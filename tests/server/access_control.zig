const std = @import("std");

const log = @import("../../src/server/logger.zig");
const Config = @import("../../src/server/config.zig").Config;
const AccessControl = @import("../../src/server/access_control.zig").AccessControl;

test "should not return errors" {
    const config = try Config.load(std.testing.allocator, null, null);
    const logger = try log.Logger.init(std.testing.allocator, null);

    const access_control = AccessControl.init(&config, &logger);
    const address = std.net.Address.initIp4(.{ 192, 168, 0, 1 }, 1234);
    var connections: u16 = 0;
    const result = access_control.verify(address, &connections);
    try std.testing.expectEqual(result, void{});
}

test "should return MaxClientsReached" {
    var config = try Config.load(std.testing.allocator, null, null);
    const logger = try log.Logger.init(std.testing.allocator, null);

    config.max_connections = 1;

    const access_control = AccessControl.init(&config, &logger);
    const address = std.net.Address.initIp4(.{ 192, 168, 0, 1 }, 1234);
    var connections: u16 = 2;
    const result = access_control.verify(address, &connections);
    try std.testing.expectEqual(result, error.MaxClientsReached);
}

test "should return NotWhitelisted" {
    var config = try Config.load(std.testing.allocator, null, null);
    const logger = try log.Logger.init(std.testing.allocator, null);

    const whitelisted = std.net.Address.initIp4(.{ 192, 168, 0, 2 }, 1234);
    var whitelist = std.ArrayList(std.net.Address).init(std.testing.allocator);
    try whitelist.append(whitelisted);
    defer whitelist.deinit();

    config.whitelist = whitelist;

    const access_control = AccessControl.init(&config, &logger);
    const address = std.net.Address.initIp4(.{ 192, 168, 0, 1 }, 1234);
    var connections: u16 = 1;
    const result = access_control.verify(address, &connections);
    try std.testing.expectEqual(result, error.NotWhitelisted);
}