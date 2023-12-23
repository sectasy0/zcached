const std = @import("std");
const protocol = @import("../protocol/handler.zig");

const AnyType = @import("../protocol/types.zig").AnyType;
const MemoryStorage = @import("storage.zig").MemoryStorage;
const errors = @import("err_handler.zig");
const CMDHandler = @import("cmd_handler.zig").CMDHandler;
const Config = @import("config.zig").Config;
const log = @import("logger.zig");

const Address = std.net.Address;
const Allocator = std.mem.Allocator;
const Pool = std.Thread.Pool;

const Connection = std.net.StreamServer.Connection;

pub const ServerListener = struct {
    server: std.net.StreamServer,
    addr: *const std.net.Address,

    allocator: Allocator,

    protocol: protocol.ProtocolHandler,
    cmd_handler: CMDHandler,
    storage: *MemoryStorage,

    config: *const Config,

    connections: u16 = 0,

    logger: *const log.Logger,
    pool: *std.Thread.Pool,

    pub fn init(
        addr: *const Address,
        allocator: Allocator,
        pool: *Pool,
        storage: *MemoryStorage,
        config: *const Config,
        logger: *const log.Logger,
    ) !ServerListener {
        const proto = protocol.ProtocolHandler.init(allocator) catch {
            return error.ProtocolInitFailed;
        };

        const cmdhandler = CMDHandler.init(allocator, storage, logger);

        logger.log(log.LogLevel.Info, "* ready to accept connections", .{});

        return ServerListener{
            .server = std.net.StreamServer.init(.{
                .kernel_backlog = 128,
                .reuse_address = true,
                .reuse_port = true,
            }),
            .allocator = allocator,
            .cmd_handler = cmdhandler,
            .protocol = proto,
            .pool = pool,
            .addr = addr,
            .storage = storage,
            .config = config,
            .logger = logger,
        };
    }

    pub fn listen(self: *ServerListener) !void {
        try self.server.listen(@constCast(self.addr).*);

        // if somewhere in there we get an error, we just translate it to a packet and send it back.
        while (true) {
            var connection: Connection = try self.server.accept();
            self.connections += 1;

            self.protocol.serializer.raw.clearRetainingCapacity();

            if (self.connections > self.config.max_connections) {
                const err = error.MaxClientsReached;
                errors.handle(connection.stream, err, .{}, self.logger) catch {
                    self.logger.log(log.LogLevel.Error, "* failed to send error: {any}", .{err});
                };
            }

            if (self.config.whitelist.capacity > 0 and !self.is_whitelisted(connection.address)) {
                self.logger.log(
                    log.LogLevel.Info,
                    "* connection from {any} is not whitelisted, rejected",
                    .{connection.address},
                );

                var err = error.NotAllowed;
                errors.handle(connection.stream, err, .{}, self.logger) catch {
                    self.logger.log(log.LogLevel.Error, "* failed to send error: {any}", .{err});
                };

                return;
            }

            self.logger.log(log.LogLevel.Info, "* new connection from {any}", .{connection.address});

            self.pool.spawn(
                handle_request,
                .{ self, connection },
            ) catch |err| {
                errors.handle(connection.stream, err, .{}, self.logger) catch {
                    self.logger.log(log.LogLevel.Error, "* failed to send error: {any}", .{err});
                };

                self.close_connection(connection);

                self.logger.log(log.LogLevel.Error, "* failed to spawn new thread {any}", .{err});
            };
        }
    }

    fn handle_request(self: *ServerListener, connection: Connection) void {
        defer self.close_connection(connection);

        const reader: std.net.Stream.Reader = connection.stream.reader();
        const result: AnyType = self.protocol.serialize(&reader) catch |err| {
            self.logger.log_request(self.protocol.repr(self.protocol.serializer.raw.items));

            errors.handle(connection.stream, err, .{}, self.logger) catch {
                self.logger.log(log.LogLevel.Error, "* failed to send error: {any}", .{err});
            };

            return;
        };

        self.logger.log_request(self.protocol.repr(self.protocol.serializer.raw.items));

        // command is always and array of bulk strings
        if (std.meta.activeTag(result) != .array) {
            errors.handle(connection.stream, error.UnknownCommand, .{}, self.logger) catch |err| {
                self.logger.log(log.LogLevel.Error, "* failed to send error: {any}", .{err});
            };
            return;
        }

        const command_set = &result.array;

        const cmd_result = self.cmd_handler.process(command_set);
        if (std.meta.activeTag(cmd_result) != .ok) {
            errors.handle(connection.stream, cmd_result.err, .{}, self.logger) catch |err| {
                self.logger.log(log.LogLevel.Error, "* failed to send error: {any}", .{err});
            };

            std.debug.print("failed to process command: {any}\n", .{self.protocol.serializer.raw.items});
            return;
        }

        var response = self.protocol.deserialize(cmd_result.ok) catch |err| {
            errors.handle(connection.stream, err, .{}, self.logger) catch |er| {
                self.logger.log(log.LogLevel.Error, "* failed to send error: {any}", .{er});
            };
            return;
        };
        connection.stream.writer().writeAll(response) catch |err| {
            errors.handle(connection.stream, err, .{}, self.logger) catch |er| {
                self.logger.log(log.LogLevel.Error, "* failed to send error: {any}", .{er});
            };
        };

        // log response
        var output = self.protocol.repr(response) catch |err| {
            self.logger.log(log.LogLevel.Error, "* failed to repr response: {any}", .{err});
            return;
        };
        defer self.allocator.free(output);
        self.logger.log(log.LogLevel.Info, "< response: {s}", .{output});
    }

    fn is_whitelisted(self: *ServerListener, addr: Address) bool {
        for (self.config.whitelist.items) |whitelisted| {
            if (std.meta.eql(whitelisted.any.data[2..].*, addr.any.data[2..].*)) return true;
        }
        return false;
    }

    fn close_connection(self: *ServerListener, connection: Connection) void {
        connection.stream.close();
        self.connections -= 1;
    }

    pub fn deinit(self: *ServerListener) void {
        self.server.deinit();
        self.protocol.deinit();
    }
};

// I dunno how to test this listener, so I'm just gonna test it manually
