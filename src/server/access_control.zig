const std = @import("std");

const log = @import("logger.zig");
const Config = @import("config.zig");
const utils = @import("utils.zig");

const AccessControl = @This();

logger: *const log.Logger,
config: *const Config,

pub fn init(config: *const Config, logger: *const log.Logger) AccessControl {
    return AccessControl{ .logger = logger, .config = config };
}

// Check whether a new connection, represented by the provided network address, can be established.
pub fn verify(self: AccessControl, address: std.net.Address) !void {
    try self.check_whitelist(address);
}

// Checks whether the provided network address is whitelisted.
// If whitelisting is enabled (whitelist capacity is greater than 0) and the given address is not whitelisted.
fn check_whitelist(
    self: AccessControl,
    address: std.net.Address,
) !void {
    if (self.config.whitelist.capacity > 0 and !utils.is_whitelisted(
        self.config.whitelist,
        address,
    )) {
        self.logger.log(
            log.LogLevel.Info,
            "* connection from {any} is not whitelisted, rejected",
            .{address},
        );

        return error.NotPermitted;
    }
}
