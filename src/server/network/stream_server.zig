//! TCP listener lifecycle, accepted connections, and optional TLS upgrades.
const std = @import("std");
const Address = @import("address.zig").Address;
const Config = @import("../config.zig");
const build_options = @import("build_options");
const secure = if (build_options.tls_enabled) @import("secure.zig") else struct {};
const Stream = @import("stream.zig").Stream;

/// Current listener type, used by its lifecycle and connection operations.
const StreamServer = @This();

/// Listener and TLS configuration chosen at initialization.
options: Options,
/// I/O backend used by the listener and TLS setup.
io: std.Io,
/// Shared server TLS context, when TLS support is compiled in and configured.
tls_ctx: if (build_options.tls_enabled) ?secure.Context else ?void = null,
/// Actual bound address, populated by `listen`.
listen_address: Address = undefined,
/// Active listener; null before listening and after `close`.
listener: ?std.Io.net.Server = null,

/// Settings controlling socket listen behavior and optional TLS.
pub const Options = struct {
    /// Kernel queue length for pending TCP accepts.
    kernel_backlog: u31 = 128,
    /// Whether the operating system may reuse the listening address.
    reuse_address: bool = false,
    /// TLS credentials and verification settings used when TLS is enabled.
    tls: Config.TLSConfig = .{},
};

/// Initializes the transport and, when configured and compiled in, loads TLS credentials.
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

/// Closes the listener, frees TLS state, and invalidates this server value.
pub fn deinit(self: *StreamServer) void {
    self.close();
    if (comptime build_options.tls_enabled) {
        if (self.tls_ctx) |*ctx| ctx.deinit();
    }
    self.* = undefined;
}

/// Binds the requested address and records the actual address selected by the OS.
pub fn listen(self: *StreamServer, address: Address) !void {
    if (self.listener != null) return error.AlreadyListening;
    self.listener = try address.ip.listen(self.io, .{
        .kernel_backlog = self.options.kernel_backlog,
        .reuse_address = self.options.reuse_address,
    });
    self.listen_address = Address.fromIp(self.listener.?.socket.address);
}

/// Stops accepting connections and clears the bound-address state.
pub fn close(self: *StreamServer) void {
    if (self.listener) |*listener| {
        listener.deinit(self.io);
        self.listener = null;
        self.listen_address = undefined;
    }
}

/// A connected stream paired with the remote peer's address.
pub const Connection = struct {
    /// Connected transport owned by the connection holder.
    stream: Stream,
    /// Remote endpoint captured when the socket was accepted.
    address: Address,
};

/// Accepts one pending socket; returns `SocketNotListening` without an active listener.
pub fn accept(self: *StreamServer, io: std.Io) std.Io.net.Server.AcceptError!Connection {
    const listener = if (self.listener) |*listener| listener else return error.SocketNotListening;
    const socket = try listener.accept(io);
    return .{
        .stream = .{ .io = io, .socket = socket },
        .address = Address.fromIp(socket.socket.address),
    };
}

/// Performs a TLS handshake in place when this server has TLS enabled.
pub fn upgrade(self: *StreamServer, stream: *Stream, timeout: std.Io.Timeout) !void {
    if (comptime build_options.tls_enabled) {
        if (self.tls_ctx) |*ctx| {
            if (stream.closed) return error.StreamClosed;
            if (stream.ctx != null) return error.TLSAlreadyInitialized;
            stream.ctx = try ctx.upgrade(stream.io, stream.socket, timeout);
        }
    }
}
