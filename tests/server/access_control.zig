const std = @import("std");

const Logger = @import("../../src/server/logger.zig");
const Config = @import("../../src/server/config.zig");
const AccessControl = @import("../../src/server/access_control.zig");

test "should not return errors" {
    const config = try Config.load(std.testing.allocator, null, null);
    const logger = try Logger.init(std.testing.allocator, null, false);

    const access_control = AccessControl.init(&config, &logger);
    const address = std.net.Address.initIp4(.{ 192, 168, 0, 1 }, 1234);
    const result = access_control.verify(address);
    try std.testing.expectEqual(result, void{});
}

test "should return error.NotPermitted" {
    var config = try Config.load(std.testing.allocator, null, null);
    const logger = try Logger.init(std.testing.allocator, null, false);

    const whitelisted = std.net.Address.initIp4(.{ 192, 168, 0, 2 }, 1234);
    var whitelist = std.ArrayList(std.net.Address).init(std.testing.allocator);
    try whitelist.append(whitelisted);
    defer whitelist.deinit();

    config.whitelist = whitelist;

    const access_control = AccessControl.init(&config, &logger);
    const address = std.net.Address.initIp4(.{ 192, 168, 0, 1 }, 1234);
    const result = access_control.verify(address);
    try std.testing.expectEqual(result, error.NotPermitted);
}
