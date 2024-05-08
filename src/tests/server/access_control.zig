const std = @import("std");

const Fixtures = @import("../fixtures.zig");
const AccessControl = @import("../../server/access_control.zig");

test "should not return errors" {
    var fixtures = try Fixtures.init();
    defer fixtures.deinit();

    const access_control = AccessControl.init(&fixtures.config, &fixtures.logger);
    const address = std.net.Address.initIp4(.{ 192, 168, 0, 1 }, 1234);
    const result = access_control.verify(address);
    try std.testing.expectEqual(result, void{});
}

test "should return error.NotPermitted" {
    var fixtures = try Fixtures.init();
    defer fixtures.deinit();

    const whitelisted = std.net.Address.initIp4(.{ 192, 168, 0, 2 }, 1234);
    var whitelist = std.ArrayList(std.net.Address).init(fixtures.allocator);
    try whitelist.append(whitelisted);
    defer whitelist.deinit();

    fixtures.config.whitelist = whitelist;

    const access_control = AccessControl.init(&fixtures.config, &fixtures.logger);
    const address = std.net.Address.initIp4(.{ 192, 168, 0, 1 }, 1234);
    const result = access_control.verify(address);
    try std.testing.expectEqual(result, error.NotPermitted);

    // Yep, without this in the logs, there is still a log about the rejected connection.
    std.fs.cwd().deleteTree("logs") catch {};
}
