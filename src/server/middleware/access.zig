const std = @import("std");
const Address = @import("../network/address.zig").Address;

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
pub fn verify(self: AccessMiddleware, address: Address) !void {
    try self.check_whitelist(address);
}

// Checks whether the provided network address is whitelisted.
// If whitelisting is enabled (whitelist capacity is greater than 0) and the given address is not whitelisted.
fn check_whitelist(
    self: AccessMiddleware,
    address: Address,
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
fn is_whitelisted(whitelist: std.array_list.Managed(Address), addr: Address) bool {
    for (whitelist.items) |whitelisted| {
        if (whitelisted.eqlIp(addr)) return true;
    }
    return false;
}
