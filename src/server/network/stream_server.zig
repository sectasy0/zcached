const std = @import("std");
const runtime_io = @import("runtime_io");
const Address = @import("address.zig").Address;

const Config = @import("../config.zig");

// Build configuration and conditional imports
const build_options = @import("build_options");
const secure = if (build_options.tls_enabled)
    @import("secure.zig")
else
    @import("unsecure.zig");

// Local modules
const Stream = @import("stream.zig");

const StreamServer = @This();

/// Copied from `Options` on `init`.
kernel_backlog: u31,
reuse_address: bool,
reuse_port: bool,
force_nonblocking: bool,

tls: Config.TLSConfig,
tls_ctx: ?secure.Context = null,

/// `undefined` until `listen` returns successfully.
listen_address: Address,

sockfd: ?std.posix.fd_t = null,
listener: ?std.Io.net.Server = null,

pub const Options = struct {
    /// How many connections the kernel will accept on the application's behalf.
    /// If more than this many connections pool in the kernel, clients will start
    /// seeing "Connection refused".
    kernel_backlog: u31 = 128,

    /// Enable SO.REUSEADDR on the socket.
    reuse_address: bool = false,

    /// Enable SO.REUSEPORT on the socket.
    reuse_port: bool = false,

    /// TLS 1.3 configuration.
    tls: Config.TLSConfig = .{},

    /// Force non-blocking mode.
    force_nonblocking: bool = false,
};

/// After this call succeeds, resources have been acquired and must
/// be released with `deinit`.
pub fn init(options: Options) !StreamServer {
    var tls_ctx: ?secure.Context = null;

    if (options.tls.enabled and build_options.tls_enabled) {
        if (options.tls.cert_path == null or options.tls.key_path == null) {
            return error.InvalidTLSConfig;
        }

        tls_ctx = try secure.Context.init(
            options.tls.key_path.?,
            options.tls.cert_path.?,
            options.tls.ca_path,
            options.tls.verify_mode,
        );
    }

    return StreamServer{
        .sockfd = null,
        .listener = null,
        .kernel_backlog = options.kernel_backlog,
        .reuse_address = options.reuse_address,
        .reuse_port = options.reuse_port,
        .force_nonblocking = options.force_nonblocking,
        .tls = options.tls,
        .tls_ctx = tls_ctx,
        .listen_address = undefined,
    };
}

/// Release all resources. The `StreamServer` memory becomes `undefined`.
pub fn deinit(self: *StreamServer) void {
    if (comptime build_options.tls_enabled) {
        if (self.tls_ctx) |ctx| ctx.deinit();
    }
    self.close();
    self.* = undefined;
}

pub fn listen(self: *StreamServer, address: Address) !void {
    const io = runtime_io.get();
    var listener = try address.ip.listen(io, .{
        .kernel_backlog = self.kernel_backlog,
        .reuse_address = self.reuse_address or self.reuse_port,
    });
    errdefer listener.deinit(io);

    try setNonblocking(listener.socket.handle);
    self.listener = listener;
    self.sockfd = listener.socket.handle;
    self.listen_address = Address.fromIp(listener.socket.address);
}

/// Stop listening. It is still necessary to call `deinit` after stopping listening.
/// Calling `deinit` will automatically call `close`. It is safe to call `close` when
/// not listening.
pub fn close(self: *StreamServer) void {
    if (self.listener) |*listener| {
        listener.deinit(runtime_io.get());
        self.listener = null;
        self.sockfd = null;
        self.listen_address = undefined;
    }
}

pub const AcceptError = error{
    ConnectionAborted,

    /// The per-process limit on the number of open file descriptors has been reached.
    ProcessFdQuotaExceeded,

    /// The system-wide limit on the total number of open files has been reached.
    SystemFdQuotaExceeded,

    /// Not enough free memory. This often means that the memory allocation
    /// is limited by the socket buffer limits, not by the system memory.
    SystemResources,

    /// Socket is not listening for new connections.
    SocketNotListening,

    ProtocolFailure,

    /// Socket is in non-blocking mode and there is no connection to accept.
    WouldBlock,

    /// Firewall rules forbid connection.
    BlockedByFirewall,

    FileDescriptorNotASocket,

    ConnectionResetByPeer,

    SSLInitFailure,
    SSLSetFdFailure,
    SSLHandshakeFailure,

    NetworkSubsystemFailed,

    OperationNotSupported,
    Canceled,
    NetworkDown,
    NonblockingSetupFailed,
} || std.posix.UnexpectedError;

pub const Connection = struct {
    stream: Stream.Stream,
    address: Address,
};

/// If this function succeeds, the returned `Connection` is a caller-managed resource.
pub fn accept(self: *StreamServer) AcceptError!Connection {
    var peer_address: std.Io.Threaded.PosixAddress = undefined;
    var peer_address_len: std.posix.socklen_t = @sizeOf(std.Io.Threaded.PosixAddress);
    const fd = std.c.accept(self.sockfd.?, &peer_address.any, &peer_address_len);
    if (fd < 0) {
        return switch (std.posix.errno(fd)) {
            .AGAIN, .INTR => error.WouldBlock,
            .CONNABORTED => error.ConnectionAborted,
            .PERM => error.BlockedByFirewall,
            else => |err| std.posix.unexpectedErrno(err),
        };
    }

    const socket_fd: std.posix.fd_t = @intCast(fd);
    const socket_file: std.Io.File = .{
        .handle = socket_fd,
        .flags = .{ .nonblocking = false },
    };
    errdefer socket_file.close(runtime_io.get());

    const descriptor_flags = std.c.fcntl(socket_fd, std.c.F.GETFD, @as(c_int, 0));
    if (descriptor_flags < 0 or std.c.fcntl(
        socket_fd,
        std.c.F.SETFD,
        descriptor_flags | std.posix.FD_CLOEXEC,
    ) < 0) return error.SystemResources;
    var stream: Stream.Stream = .{ .handle = socket_fd, .ctx = null };
    errdefer stream.close();
    if (build_options.tls_enabled) {
        if (self.tls_ctx) |ctx| try ctx.upgrade(&stream);
    }
    try setNonblocking(socket_fd);

    return Connection{
        .stream = stream,
        .address = Address.fromIp(std.Io.Threaded.addressFromPosix(&peer_address)),
    };
}

fn setNonblocking(fd: std.posix.fd_t) error{NonblockingSetupFailed}!void {
    const flags = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
    const nonblocking_flag: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
    if (flags < 0 or std.c.fcntl(fd, std.c.F.SETFL, flags | nonblocking_flag) < 0) {
        return error.NonblockingSetupFailed;
    }
}
