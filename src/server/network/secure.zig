const std = @import("std");
const socket_io = @import("socket.zig");
const VerifyMode = @import("../config.zig").TLSConfig.VerifyMode;

pub const openssl = @import("openssl");

pub const Error = socket_io.Error || error{
    TLSProtocolError,
    TLSUnexpectedEof,
    TLSNoProgress,
    TLSBioFailure,
};

pub const Context = struct {
    ctx: *openssl.SSL_CTX,

    pub fn init(key: []const u8, cert: []const u8, ca: ?[]const u8, verify_mode: VerifyMode) !Context {
        const ctx = openssl.SSL_CTX_new(openssl.TLS_server_method()) orelse return error.SSLContextFailure;
        errdefer openssl.SSL_CTX_free(ctx);
        if (openssl.SSL_CTX_set_min_proto_version(ctx, openssl.TLS1_3_VERSION) != 1) return error.SSLMinVersion;

        var cert_buffer: [std.posix.PATH_MAX]u8 = undefined;
        var key_buffer: [std.posix.PATH_MAX]u8 = undefined;
        const certz = try std.mem.printSentinel(&cert_buffer, "{s}", .{cert}, 0);
        const keyz = try std.mem.printSentinel(&key_buffer, "{s}", .{key}, 0);
        const mode = switch (verify_mode) {
            .none => openssl.SSL_VERIFY_NONE,
            .peer => openssl.SSL_VERIFY_PEER,
            .fail_if_no_peer_cert => openssl.SSL_VERIFY_PEER | openssl.SSL_VERIFY_FAIL_IF_NO_PEER_CERT,
            .client_once => openssl.SSL_VERIFY_PEER | openssl.SSL_VERIFY_CLIENT_ONCE,
        };
        openssl.SSL_CTX_set_verify(ctx, mode, null);
        if (ca) |path| {
            var ca_buffer: [std.posix.PATH_MAX]u8 = undefined;
            const caz = try std.mem.printSentinel(&ca_buffer, "{s}", .{path}, 0);
            if (openssl.SSL_CTX_load_verify_locations(ctx, caz.ptr, null) != 1) return error.CALoadFailure;
        }
        if (openssl.SSL_CTX_use_certificate_file(ctx, certz.ptr, openssl.SSL_FILETYPE_PEM) != 1) return error.CertFailure;
        if (openssl.SSL_CTX_use_PrivateKey_file(ctx, keyz.ptr, openssl.SSL_FILETYPE_PEM) != 1) return error.KeyFailure;
        if (openssl.SSL_CTX_check_private_key(ctx) != 1) return error.InvalidKey;
        return .{ .ctx = ctx };
    }

    pub fn upgrade(self: *const Context, io: std.Io, socket: std.Io.net.Stream) !StreamContext {
        return upgradeWithContext(io, self.ctx, socket, false);
    }

    pub fn deinit(self: *Context) void {
        openssl.SSL_CTX_free(self.ctx);
    }
};

/// E2E client helper; certificate verification is intentionally disabled.
pub fn upgradeClient(io: std.Io, socket: std.Io.net.Stream) !StreamContext {
    const ctx = openssl.SSL_CTX_new(openssl.TLS_client_method()) orelse return error.SSLContextFailure;
    defer openssl.SSL_CTX_free(ctx);
    if (openssl.SSL_CTX_set_min_proto_version(ctx, openssl.TLS1_3_VERSION) != 1) return error.SSLMinVersion;
    openssl.SSL_CTX_set_verify(ctx, openssl.SSL_VERIFY_NONE, null);
    return upgradeWithContext(io, ctx, socket, true);
}

fn upgradeWithContext(io: std.Io, ctx: *openssl.SSL_CTX, socket: std.Io.net.Stream, client: bool) !StreamContext {
    const ssl = openssl.SSL_new(ctx) orelse return error.SSLInitFailure;
    errdefer openssl.SSL_free(ssl);
    const input = openssl.BIO_new(openssl.BIO_s_mem()) orelse return error.TLSBioFailure;
    const output = openssl.BIO_new(openssl.BIO_s_mem()) orelse {
        _ = openssl.BIO_free(input);
        return error.TLSBioFailure;
    };
    openssl.SSL_set_bio(ssl, input, output);
    if (client) openssl.SSL_set_connect_state(ssl) else openssl.SSL_set_accept_state(ssl);

    var state = StreamContext{ .io = io, .ssl = ssl, .input = input, .output = output };
    try state.handshake(socket);
    return state;
}

pub const StreamContext = struct {
    io: std.Io,
    ssl: *openssl.SSL,
    input: *openssl.BIO,
    output: *openssl.BIO,

    pub fn deinit(self: *StreamContext) void {
        // Closing the socket is nonblocking; no TLS close_notify exchange is attempted.
        openssl.SSL_free(self.ssl);
    }

    fn flush(self: *StreamContext, socket: std.Io.net.Stream) Error!usize {
        var buffer: [16384]u8 = undefined;
        var total: usize = 0;
        while (openssl.BIO_ctrl_pending(self.output) > 0) {
            const n = openssl.BIO_read(self.output, &buffer, buffer.len);
            if (n <= 0) return error.TLSBioFailure;
            const length: usize = @intCast(n);
            try socket_io.writeAll(self.io, socket, buffer[0..length]);
            total += length;
        }
        return total;
    }

    fn receive(self: *StreamContext, socket: std.Io.net.Stream) Error!void {
        var buffer: [16384]u8 = undefined;
        const count = try socket_io.read(self.io, socket, &buffer);
        if (count == 0) return error.TLSUnexpectedEof;
        var offset: usize = 0;
        while (offset < count) {
            const n = openssl.BIO_write(self.input, buffer[offset..count].ptr, @intCast(count - offset));
            if (n <= 0) return error.TLSBioFailure;
            offset += @intCast(n);
        }
    }

    fn proceed(self: *StreamContext, socket: std.Io.net.Stream, status: c_int) Error!void {
        const flushed = try self.flush(socket);
        switch (status) {
            openssl.SSL_ERROR_WANT_READ => try self.receive(socket),
            openssl.SSL_ERROR_WANT_WRITE => if (flushed == 0) return error.TLSNoProgress,
            else => return error.TLSProtocolError,
        }
    }

    fn handshake(self: *StreamContext, socket: std.Io.net.Stream) Error!void {
        while (true) {
            openssl.ERR_clear_error();
            const result = openssl.SSL_do_handshake(self.ssl);
            const status = if (result == 1) openssl.SSL_ERROR_NONE else openssl.SSL_get_error(self.ssl, result);
            if (result == 1) {
                _ = try self.flush(socket);
                return;
            }
            try self.proceed(socket, status);
        }
    }

    pub fn read(self: *StreamContext, socket: std.Io.net.Stream, buffer: []u8) Error!usize {
        while (true) {
            openssl.ERR_clear_error();
            const result = openssl.SSL_read(self.ssl, buffer.ptr, @intCast(@min(buffer.len, std.math.maxInt(c_int))));
            const status = if (result > 0) openssl.SSL_ERROR_NONE else openssl.SSL_get_error(self.ssl, result);
            if (result > 0) {
                _ = try self.flush(socket);
                return @intCast(result);
            }
            if (status == openssl.SSL_ERROR_ZERO_RETURN) {
                _ = try self.flush(socket);
                return 0;
            }
            try self.proceed(socket, status);
        }
    }

    pub fn write(self: *StreamContext, socket: std.Io.net.Stream, bytes: []const u8) Error!usize {
        while (true) {
            openssl.ERR_clear_error();
            const result = openssl.SSL_write(self.ssl, bytes.ptr, @intCast(@min(bytes.len, std.math.maxInt(c_int))));
            const status = if (result > 0) openssl.SSL_ERROR_NONE else openssl.SSL_get_error(self.ssl, result);
            if (result > 0) {
                _ = try self.flush(socket);
                return @intCast(result);
            }
            if (status == openssl.SSL_ERROR_ZERO_RETURN) return error.TLSUnexpectedEof;
            try self.proceed(socket, status);
        }
    }
};
