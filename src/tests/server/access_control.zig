const std = @import("std");

const Logger = @import("../../server/logger.zig");
const Config = @import("../../server/config.zig");
const AccessControl = @import("../../server/access_control.zig");

test "should not return errors" {
    const config = try Config.load(std.testing.allocator, null, null);
    var logger = try Logger.init(std.testing.allocator, null, false);

    const access_control = AccessControl.init(&config, &logger);
    const address = std.net.Address.initIp4(.{ 192, 168, 0, 1 }, 1234);
    const result = access_control.verify(address);
    try std.testing.expectEqual(result, void{});
}

test "should return error.NotPermitted" {
    var config = try Config.load(std.testing.allocator, null, null);
    var logger = try Logger.init(std.testing.allocator, null, false);

    const whitelisted = std.net.Address.initIp4(.{ 192, 168, 0, 2 }, 1234);
    var whitelist = std.ArrayList(std.net.Address).init(std.testing.allocator);
    try whitelist.append(whitelisted);
    defer whitelist.deinit();

    config.whitelist = whitelist;

    const access_control = AccessControl.init(&config, &logger);
    const address = std.net.Address.initIp4(.{ 192, 168, 0, 1 }, 1234);
    const result = access_control.verify(address);
    try std.testing.expectEqual(result, error.NotPermitted);

    // Yep, without this in the logs, there is still a log about the rejected connection.
    std.fs.cwd().deleteTree("logs") catch {};
}
