const std = @import("std");
const fs = @import("fs");
const Address = @import("../../server/network/address.zig").Address;

const fixtures = @import("../fixtures.zig");
const ContextFixture = fixtures.ContextFixture;

const access = @import("../../server/middleware/access.zig");

test "should not return errors" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();

    const whitelist = std.array_list.Managed(Address).init(fixture.allocator);
    const previous_whitelist = fixture.config.whitelist;
    defer previous_whitelist.deinit();

    fixture.config.whitelist = whitelist;

    const address = Address.initIp4(.{ 192, 168, 0, 2 }, 1234);
    const result = access.verify(&fixture.config, &fixture.logger, address);
    try std.testing.expectEqual(result, {});
}

test "should return error.NotPermitted" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    const previous_whitelist = fixture.config.whitelist;

    const whitelisted = Address.initIp4(.{ 192, 168, 0, 2 }, 1234);
    var whitelist = std.array_list.Managed(Address).init(fixture.allocator);
    try whitelist.append(whitelisted);
    defer previous_whitelist.deinit();

    fixture.config.whitelist = whitelist;

    const address = Address.initIp4(.{ 192, 168, 0, 1 }, 1234);
    const result = access.verify(&fixture.config, &fixture.logger, address);
    try std.testing.expectEqual(result, error.NotPermitted);

    // Yep, without this in the logs, there is still a log about the rejected connection.
    fs.cwd().deleteTree("log") catch {};
}

test "whitelist matches IP regardless of client port" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();

    var whitelist = std.array_list.Managed(Address).init(fixture.allocator);
    try whitelist.append(Address.initIp4(.{ 127, 0, 0, 1 }, 7556));
    const previous_whitelist = fixture.config.whitelist;
    defer previous_whitelist.deinit();
    fixture.config.whitelist = whitelist;

    try access.verify(&fixture.config, &fixture.logger, Address.initIp4(.{ 127, 0, 0, 1 }, 64550));
}
