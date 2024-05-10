const std = @import("std");

const fixtures = @import("../fixtures.zig");
const ContextFixture = fixtures.ContextFixture;

const AccessMiddleware = @import("../../server/middleware/access.zig");

test "should not return errors" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();

    const access_control = AccessMiddleware.init(&fixture.config, &fixture.logger);
    const address = std.net.Address.initIp4(.{ 192, 168, 0, 1 }, 1234);
    const result = access_control.verify(address);
    try std.testing.expectEqual(result, void{});
}

test "should return error.NotPermitted" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();

    const whitelisted = std.net.Address.initIp4(.{ 192, 168, 0, 2 }, 1234);
    var whitelist = std.ArrayList(std.net.Address).init(fixture.allocator);
    try whitelist.append(whitelisted);
    defer whitelist.deinit();

    fixture.config.whitelist = whitelist;

    const access_control = AccessMiddleware.init(&fixture.config, &fixture.logger);
    const address = std.net.Address.initIp4(.{ 192, 168, 0, 1 }, 1234);
    const result = access_control.verify(address);
    try std.testing.expectEqual(result, error.NotPermitted);

    // Yep, without this in the logs, there is still a log about the rejected connection.
    std.fs.cwd().deleteTree("logs") catch {};
}
