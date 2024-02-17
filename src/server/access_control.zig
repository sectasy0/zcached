const std = @import("std");

const log = @import("logger.zig");
const Config = @import("config.zig").Config;
const utils = @import("utils.zig");

pub const AccessControl = struct {
    logger: *const log.Logger,
    config: *const Config,

    pub fn init(config: *const Config, logger: *const log.Logger) AccessControl {
        return AccessControl{ .logger = logger, .config = config };
    }

    // Check whether a new connection, represented by the provided network address, can be established.
    //
    // # Arguments
    // * `self` - The AccessControl instance managing access control configurations.
    // * `address` - The network address of the incoming connection to be verified.
    // * `connections` - A pointer to the current number of active connections.
    pub fn verify(self: AccessControl, address: std.net.Address, connections: *u16) !void {
        try self.check_connection_limit(connections);
        try self.allow_whitelisted(address);
    }

    // Checks whether the current number of connections exceeds the maximum allowed
    // connections specified in config file.
    // # Arguments
    // * `self` - The AccessControl instance managing access control configurations.
    // * `connections` - A pointer to the current number of active connections.
    fn check_connection_limit(self: AccessControl, connections: *u16) !void {
        if (connections.* > self.config.max_connections) {
            self.logger.log(
                log.LogLevel.Info,
                "* maximum connection exceeds, rejected",
                .{},
            );
            return error.MaxClientsReached;
        }
    }

    // Checks whether the provided network address is whitelisted.
    // If whitelisting is enabled (whitelist capacity is greater than 0) and the given address is not whitelisted
    //
    // # Arguments
    // * `self` - The AccessControl instance managing access control configurations.
    // * `address` - The network address of the incoming connection to be checked.
    fn allow_whitelisted(
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

            return error.NotWhitelisted;
        }
    }
};
