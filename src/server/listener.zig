const std = @import("std");

const ProtocolHandler = @import("../protocol/handler.zig").ProtocolHandler;
const AccessControl = @import("access_control.zig").AccessControl;
const MemoryStorage = @import("storage.zig").MemoryStorage;
const ZType = @import("../protocol/types.zig").ZType;
const CMDHandler = @import("cmd_handler.zig").CMDHandler;
const Config = @import("config.zig").Config;

const errors = @import("err_handler.zig");
const log = @import("logger.zig");
const utils = @import("utils.zig");

const Address = std.net.Address;
const Allocator = std.mem.Allocator;
const Pool = std.Thread.Pool;

const Connection = std.net.StreamServer.Connection;

pub const ServerListener = struct {
    server: std.net.StreamServer,
    addr: *const Address,

    allocator: Allocator,
    cmd_handler: CMDHandler,
    storage: *MemoryStorage,

    config: *const Config,

    connections: u16 = 0,

    logger: *const log.Logger,
    pool: *Pool,

    pub fn init(
        addr: *const Address,
        allocator: Allocator,
        pool: *Pool,
        storage: *MemoryStorage,
        config: *const Config,
        logger: *const log.Logger,
    ) !ServerListener {
        const serializer = @import("../protocol/serializer.zig");
        serializer.MAX_BULK_LEN = config.proto_max_bulk_len;

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

            self.logger.log(
                log.LogLevel.Info,
                "* new connection from {any}",
                .{connection.address},
            );

            const access_control = AccessControl.init(self.config, self.logger);
            access_control.verify(connection.address, &self.connections) catch |err| {
                errors.handle(connection.stream, err, .{}, self.logger) catch {
                    self.logger.log(log.LogLevel.Error, "* failed to send error: {any}", .{err});
                };

                self.close_connection(connection);
            };

            self.connections += 1;

            // Adds Task to the queue, then workers do its stuff
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

        var protocol = ProtocolHandler.init(self.allocator) catch return;
        defer protocol.deinit();

        // reading data from client and then try to parse to protocol.
        const reader: std.net.Stream.Reader = connection.stream.reader();
        const result: ZType = protocol.serialize(&reader) catch |err| {
            self.logger.log_event(log.EType.Request, protocol.serializer.raw.items);

            errors.handle(connection.stream, err, .{}, self.logger) catch {
                self.logger.log(log.LogLevel.Error, "* failed to send error: {any}", .{err});
            };

            return;
        };

        self.logger.log_event(log.EType.Request, protocol.serializer.raw.items);

        // command is always and array of bulk strings. Processing command below.
        if (result != .array) {
            errors.handle(connection.stream, error.UnknownCommand, .{}, self.logger) catch |err| {
                self.logger.log(log.LogLevel.Error, "* failed to send error: {any}", .{err});
            };
            return;
        }

        const command_set = &result.array;
        defer command_set.deinit();

        var cmd_result = self.cmd_handler.process(command_set);
        if (cmd_result != .ok) {
            var args = errors.build_args(command_set);
            errors.handle(connection.stream, cmd_result.err, args, self.logger) catch |err| {
                self.logger.log(log.LogLevel.Error, "* failed to send error: {any}", .{err});
            };

            std.debug.print("failed to process command: {any}\n", .{protocol.serializer.raw.items});
            return;
        }

        // need to free if is map or array.
        defer switch (cmd_result.ok) {
            .map => cmd_result.ok.map.deinit(),
            .array => cmd_result.ok.array.deinit(),
            inline else => {},
        };

        var response = protocol.deserialize(cmd_result.ok) catch |err| {
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

        self.logger.log_event(log.EType.Response, response);
    }

    fn close_connection(self: *ServerListener, connection: Connection) void {
        connection.stream.close();
        self.connections -= 1;
    }

    pub fn deinit(self: *ServerListener) void {
        self.server.deinit();
    }
};

// I dunno how to test this listener, so I'm just gonna test it manually
