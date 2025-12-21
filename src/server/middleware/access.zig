const std = @import("std");

const Logger = @import("../logger.zig");
const Config = @import("../config.zig");
const utils = @import("../utils.zig");

pub const AccessMiddleware = @This();

logger: *Logger,
config: *const Config,

pub fn init(config: *const Config, logger: *Logger) AccessMiddleware {
    return AccessMiddleware{ .logger = logger, .config = config };
}

// Check whether a new connection, represented by the provided network address, can be established.
pub fn verify(self: AccessMiddleware, address: std.net.Address) !void {
    try self.check_whitelist(address);
}

// Checks whether the provided network address is whitelisted.
// If whitelisting is enabled (whitelist capacity is greater than 0) and the given address is not whitelisted.
fn check_whitelist(
    self: AccessMiddleware,
    address: std.net.Address,
) !void {
    if (self.config.whitelist.capacity > 0 and !is_whitelisted(
        self.config.whitelist,
        address,
    )) {
        self.logger.info(
            "* connection from {any} is not whitelisted, rejected",
            .{address},
        );

        return error.NotPermitted;
    }
}

// Checks if the provided network address is present in the given whitelist.
fn is_whitelisted(whitelist: std.array_list.Managed(std.net.Address), addr: std.net.Address) bool {
    for (whitelist.items) |whitelisted| {
        if (std.meta.eql(whitelisted.any.data[2..].*, addr.any.data[2..].*)) return true;
    }
    return false;
}
