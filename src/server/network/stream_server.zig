const std = @import("std");
const Address = @import("address.zig").Address;
const Config = @import("../config.zig");
const build_options = @import("build_options");
const secure = if (build_options.tls_enabled) @import("secure.zig") else struct {};
const Stream = @import("stream.zig").Stream;

const StreamServer = @This();

options: Options,
io: std.Io,
tls_ctx: if (build_options.tls_enabled) ?secure.Context else ?void = null,
listen_address: Address = undefined,
listener: ?std.Io.net.Server = null,

pub const Options = struct {
    kernel_backlog: u31 = 128,
    reuse_address: bool = false,
    tls: Config.TLSConfig = .{},
};

pub fn init(io: std.Io, options: Options) !StreamServer {
    var result: StreamServer = .{ .io = io, .options = options };
    if (comptime build_options.tls_enabled) {
        if (options.tls.enabled) {
            result.tls_ctx = try secure.Context.init(
                options.tls.key_path orelse return error.InvalidTLSConfig,
                options.tls.cert_path orelse return error.InvalidTLSConfig,
                options.tls.ca_path,
                options.tls.verify_mode,
            );
        }
    }
    return result;
}

pub fn deinit(self: *StreamServer) void {
    self.close();
    if (comptime build_options.tls_enabled) {
        if (self.tls_ctx) |*ctx| ctx.deinit();
    }
    self.* = undefined;
}

pub fn listen(self: *StreamServer, address: Address) !void {
    if (self.listener != null) return error.AlreadyListening;
    self.listener = try address.ip.listen(self.io, .{
        .kernel_backlog = self.options.kernel_backlog,
        .reuse_address = self.options.reuse_address,
    });
    self.listen_address = Address.fromIp(self.listener.?.socket.address);
}

pub fn close(self: *StreamServer) void {
    if (self.listener) |*listener| {
        listener.deinit(self.io);
        self.listener = null;
        self.listen_address = undefined;
    }
}

pub const Connection = struct {
    stream: Stream,
    address: Address,
};

pub fn accept(self: *StreamServer, io: std.Io) std.Io.net.Server.AcceptError!Connection {
    const listener = if (self.listener) |*listener| listener else return error.SocketNotListening;
    const socket = try listener.accept(io);
    return .{
        .stream = .{ .io = io, .socket = socket },
        .address = Address.fromIp(socket.socket.address),
    };
}

pub fn upgrade(self: *StreamServer, stream: *Stream) !void {
    if (comptime build_options.tls_enabled) {
        if (self.tls_ctx) |*ctx| {
            if (stream.closed) return error.StreamClosed;
            if (stream.ctx != null) return error.TLSAlreadyInitialized;
            stream.ctx = try ctx.upgrade(stream.io, stream.socket);
        }
    }
}
