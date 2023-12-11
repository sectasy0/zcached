const std = @import("std");
const protocol = @import("../protocol/handler.zig");

const AnyType = @import("../protocol/types.zig").AnyType;
const MemoryStorage = @import("../storage.zig").MemoryStorage;
const errors = @import("err_handler.zig");
const CMDHandler = @import("cmd_handler.zig").CMDHandler;

const Address = std.net.Address;
const Allocator = std.mem.Allocator;
const Pool = std.Thread.Pool;

const Connection = std.net.StreamServer.Connection;

pub const ServerListener = struct {
    server: std.net.StreamServer,
    addr: *const std.net.Address,

    protocol: protocol.ProtocolHandler,
    cmd_handler: CMDHandler,
    storage: *MemoryStorage,

    pool: *std.Thread.Pool,

    pub fn init(addr: *const Address, allocator: Allocator, pool: *Pool, storage: *MemoryStorage) !ServerListener {
        const proto = protocol.ProtocolHandler.init(allocator) catch {
            return error.ProtocolInitFailed;
        };

        const cmdhandler = CMDHandler.init(allocator, storage);

        return ServerListener{
            .server = std.net.StreamServer.init(.{
                .kernel_backlog = 128,
                .reuse_address = true,
                .reuse_port = true,
            }),
            .cmd_handler = cmdhandler,
            .protocol = proto,
            .pool = pool,
            .addr = addr,
            .storage = storage,
        };
    }

    pub fn listen(self: *ServerListener) !void {
        try self.server.listen(@constCast(self.addr).*);

        // if somewhere in there we get an error, we just translate it to a packet and send it back.
        while (true) {
            var connection: Connection = try self.server.accept();

            std.log.info("got connection from {}\n", .{connection.address});

            self.pool.spawn(
                handle_request,
                .{ self, connection },
            ) catch |err| {
                std.log.err("error spawning thread: {}\n", .{err});
            };
        }
    }

    fn handle_request(self: *ServerListener, connection: Connection) void {
        defer connection.stream.close();

        const reader: std.net.Stream.Reader = connection.stream.reader();
        const result: AnyType = self.protocol.serialize(&reader) catch |err| {
            errors.handle(connection.stream, err, .{}) catch {
                std.log.err("error sending error: {}\n", .{err});
            };

            return;
        };

        // command is always and array of bulk strings
        if (std.meta.activeTag(result) != .array) {
            errors.handle(connection.stream, error.ProtocolInvalidRequest, .{}) catch {
                std.log.err("error sending error:\n", .{});
            };
            return;
        }

        const command_set = &result.array;

        const cmd_result = self.cmd_handler.process(command_set);
        if (std.meta.activeTag(cmd_result) != .ok) {
            errors.handle(connection.stream, cmd_result.err, .{}) catch {
                std.log.err("error sending error:\n", .{});
            };
            return;
        }

        var response = self.protocol.deserialize(cmd_result.ok) catch |err| {
            errors.handle(connection.stream, err, .{}) catch {
                std.log.err("error sending error:\n", .{});
            };
            return;
        };
        connection.stream.writer().writeAll(response) catch |err| {
            errors.handle(connection.stream, err, .{}) catch {
                std.log.err("error sending error:\n", .{});
            };
        };
    }

    pub fn deinit(self: *ServerListener) void {
        self.server.deinit();
        self.protocol.deinit();
    }
};
