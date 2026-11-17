//! Client-address whitelist checks applied before serving a network connection.
const Address = @import("../network/address.zig").Address;
const Logger = @import("../logger.zig");
const Config = @import("../config.zig");

/// Allows an address if the whitelist is empty or contains the same IP, ignoring its port.
/// Logs rejected clients and returns `NotPermitted`; the configuration and logger are borrowed.
pub fn verify(config: *const Config, logger: *Logger, address: Address) error{NotPermitted}!void {
    if (config.whitelist.capacity == 0) return;
    for (config.whitelist.items) |whitelisted| {
        if (whitelisted.eqlIp(address)) return;
    }
    logger.info("* connection from {any} is not whitelisted, rejected", .{address});
    return error.NotPermitted;
}
