const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;

const VerifyMode = @import("../config.zig").TLSConfig.VerifyMode;

// C libraries
pub const openssl = @cImport({
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/err.h");
});

// Local modules
const utils = @import("../utils.zig");
const Stream = @import("stream.zig").Stream;

const OPENSSL_SUCCESS: c_int = 1;

pub const SSL_ERROR = enum(i32) {
    NONE = 0,
    SSL = 1,
    WANT_READ = 2,
    WANT_WRITE = 3,
    SYSCALL = 5,
    ZERO_RETURN = 6,
    WANT_CONNECT = 7,
};

pub const Context = struct {
    ctx: *openssl.SSL_CTX = undefined,

    pub fn init(key: []const u8, cert: []const u8, ca: ?[]const u8, verify_mode: VerifyMode) !Context {
        const ctx: *openssl.SSL_CTX = openssl.SSL_CTX_new(openssl.TLS_server_method()) orelse {
            printSSLErrors();
            return error.SSLContextFailure;
        };
        errdefer openssl.SSL_CTX_free(ctx);

        if (openssl.SSL_CTX_set_min_proto_version(
            ctx,
            openssl.TLS1_3_VERSION,
        ) != OPENSSL_SUCCESS) {
            printSSLErrors();
            return error.SSLMinVersion;
        }

        var buffer: [std.posix.PATH_MAX]u8 = undefined;
        var key_buffer: [std.posix.PATH_MAX]u8 = undefined;
        const certz: [:0]u8 = try std.fmt.bufPrintZ(&buffer, "{s}", .{cert});
        const keyz: [:0]u8 = try std.fmt.bufPrintZ(&key_buffer, "{s}", .{key});

        openssl.SSL_CTX_set_info_callback(ctx, ssl_info_callback);

        const openssl_verify_mode = switch (verify_mode) {
            .none => openssl.SSL_VERIFY_NONE,
            .peer => openssl.SSL_VERIFY_PEER,
            .fail_if_no_peer_cert => openssl.SSL_VERIFY_PEER | openssl.SSL_VERIFY_FAIL_IF_NO_PEER_CERT,
            .client_once => openssl.SSL_VERIFY_PEER | openssl.SSL_VERIFY_CLIENT_ONCE,
        };

        openssl.SSL_CTX_set_verify(ctx, openssl_verify_mode, null);

        if (ca) |ca_path| {
            if (openssl.SSL_CTX_load_verify_locations(
                ctx,
                ca_path.ptr,
                null,
            ) != OPENSSL_SUCCESS) {
                printSSLErrors();
                return error.CALoadFailure;
            }
        }

        _ = openssl.SSL_CTX_set_mode(ctx, openssl.SSL_MODE_AUTO_RETRY);

        if (openssl.SSL_CTX_use_certificate_file(
            ctx,
            certz.ptr,
            openssl.SSL_FILETYPE_PEM,
        ) != OPENSSL_SUCCESS) {
            printSSLErrors();
            return error.CertFailure;
        }

        if (openssl.SSL_CTX_use_PrivateKey_file(
            ctx,
            keyz.ptr,
            openssl.SSL_FILETYPE_PEM,
        ) != OPENSSL_SUCCESS) {
            printSSLErrors();
            return error.KeyFailure;
        }

        if (openssl.SSL_CTX_check_private_key(ctx) != OPENSSL_SUCCESS) {
            printSSLErrors();
            return error.InvalidKey;
        }

        return .{ .ctx = ctx };
    }

    pub fn upgrade(self: *const Context, stream: *Stream) !void {
        const ctx = openssl.SSL_new(self.ctx) orelse return error.SSLInitFailure;

        var return_code: c_int = undefined;

        // https://docs.openssl.org/master/man3/SSL_set_fd/#return-values
        // 0 - The operation failed. Check the error stack to find out why.
        // 1 - The operation succeeded.
        return_code = openssl.SSL_set_fd(ctx, stream.handle);
        if (return_code == 0) {
            // const rc: i32 = @intCast(openssl.SSL_get_error(ctx, return_code));
            openssl.SSL_free(ctx);
            return error.SSLSetFdFailure;
        }

        openssl.SSL_set_accept_state(ctx);

        while (true) {
            // https://docs.openssl.org/3.0/man3/SSL_accept/#return-values
            // 1 - The TLS/SSL handshake was successfully completed, a TLS/SSL connection has been established.
            return_code = @intCast(openssl.SSL_accept(ctx));
            if (return_code == 1) break;

            // Determine the error code if SSL_accept fails
            const rc: i32 = @intCast(openssl.SSL_get_error(ctx, return_code));
            const error_code: SSL_ERROR = @enumFromInt(rc);

            // Handle non-fatal errors by continuing to retry
            switch (error_code) {
                SSL_ERROR.WANT_READ,
                SSL_ERROR.WANT_WRITE,
                SSL_ERROR.WANT_CONNECT,
                => continue,
                else => {
                    openssl.SSL_free(ctx);
                    return error.SSLHandshakeFailure;
                },
            }
        }

        stream.ctx = .{ .ctx = ctx };
    }

    pub fn deinit(self: *Context) void {
        openssl.SSL_CTX_free(self.ctx);
    }
};

pub const StreamContext = struct {
    ctx: ?*anyopaque = null,

    pub fn deinit(self: *StreamContext) void {
        if (self.ctx) |ssl| {
            var rc: c_int = openssl.SSL_shutdown(ssl);

            if (rc == 0) {
                rc = openssl.SSL_shutdown(ssl);
            }

            if (rc < 0) {
                const err_code = openssl.SSL_get_error(ssl, rc);
                const enum_error: SSL_ERROR = @enumFromInt(err_code);
                switch (enum_error) {
                    .WANT_READ,
                    .WANT_WRITE,
                    => {}, // forcing shutdown, so we can ignore these errors
                    .ZERO_RETURN => {}, // connection was closed cleanly, so we can ignore this
                    else => printSSLErrors(),
                }
            }

            openssl.SSL_free(ssl);
            self.ctx = null;
        }
    }
};

fn ssl_info_callback(ssl: ?*const openssl.SSL, t: c_int, v: c_int) callconv(.C) void {
    _ = ssl;

    var timestamp: [40]u8 = undefined;
    const t_size = utils.timestampf(&timestamp);
    std.debug.print(
        "INFO [{s}] SSL_info callback: type={any}, val={any}\n",
        .{ timestamp[0..t_size], t, v },
    );
}

pub fn printSSLErrors() void {
    const bio = openssl.BIO_new(openssl.BIO_s_mem());
    defer _ = openssl.BIO_free(bio);
    openssl.ERR_print_errors(bio);
    var buf: [*]u8 = undefined;
    const len: usize = @intCast(openssl.BIO_get_mem_data(bio, &buf));
    if (len > 0) {
        var timestamp: [40]u8 = undefined;
        const t_size = utils.timestampf(&timestamp);
        std.debug.print(
            "ERROR [{s}] {s}\n",
            .{ timestamp[0..t_size], buf[0..len] },
        );
    }
}

pub fn read(ctx_ptr: ?*anyopaque, buffer: []u8) !usize {
    if (ctx_ptr == null) return error.SSLProtocolError;

    const ctx: ?*openssl.SSL = @ptrCast(ctx_ptr);

    const max_count = switch (native_os) {
        .linux => 0x7ffff000,
        .macos, .ios, .watchos, .tvos, .visionos => std.math.maxInt(i32),
        else => std.math.maxInt(isize),
    };

    while (true) {
        const result = openssl.SSL_read(ctx, buffer.ptr, @min(buffer.len, max_count));
        const rc: u32 = @intCast(openssl.SSL_get_error(ctx, result));

        const error_code: SSL_ERROR = @enumFromInt(rc);
        switch (error_code) {
            SSL_ERROR.NONE => return @intCast(result), // Successful read, return the number of bytes read
            SSL_ERROR.ZERO_RETURN => return error.SocketNotConnected, // SSL connection was closed cleanly
            SSL_ERROR.WANT_READ => return error.WouldBlock, // Non-blocking read requested more data, so retry
            SSL_ERROR.WANT_WRITE => return error.WouldBlock, // Retry due to "want write" condition in a read
            SSL_ERROR.WANT_CONNECT => return error.WouldBlock,
            SSL_ERROR.SYSCALL => {
                // System-level error encountered, return specific system errors
                switch (std.posix.errno(rc)) {
                    .SUCCESS => return @intCast(buffer.len),
                    .INTR => continue,
                    .INVAL => unreachable,
                    .FAULT => unreachable,
                    .AGAIN => return error.WouldBlock,
                    .BADF => return error.NotOpenForReading,
                    .IO => return error.InputOutput,
                    .NOBUFS => return error.SystemResources,
                    .NOMEM => return error.SystemResources,
                    .NOTCONN => return error.SocketNotConnected,
                    .CONNRESET => return error.ConnectionResetByPeer,
                    .TIMEDOUT => return error.ConnectionTimedOut,
                    else => |err| return std.posix.unexpectedErrno(err),
                }
            },
            SSL_ERROR.SSL => return error.SSLProtocolError,
        }
    }
}

pub fn write(ctx_ptr: ?*anyopaque, buffer: []const u8) !usize {
    if (ctx_ptr == null) return error.SSLProtocolError;

    const ctx: ?*openssl.SSL = @ptrCast(ctx_ptr);

    const max_count = switch (native_os) {
        .linux => 0x7ffff000,
        .macos, .ios, .watchos, .tvos, .visionos => std.math.maxInt(i32),
        else => std.math.maxInt(isize),
    };

    while (true) {
        openssl.ERR_clear_error();

        const result = openssl.SSL_write(ctx, buffer.ptr, @min(buffer.len, max_count));
        const rc: u32 = @intCast(openssl.SSL_get_error(ctx, result));

        const error_code: SSL_ERROR = @enumFromInt(rc);

        switch (error_code) {
            SSL_ERROR.NONE => return @intCast(result), // Successful read, return the number of bytes read
            SSL_ERROR.ZERO_RETURN => return error.ConnectionResetByPeer, // SSL connection was closed cleanly
            SSL_ERROR.WANT_READ => return error.WouldBlock, // Non-blocking read requested more data, so retry
            SSL_ERROR.WANT_WRITE => return error.WouldBlock, // Retry due to "want write" condition in a read
            SSL_ERROR.WANT_CONNECT => return error.WouldBlock,
            SSL_ERROR.SYSCALL => {
                // System-level error encountered, return specific system errors
                switch (std.posix.errno(rc)) {
                    .INTR => continue,
                    .INVAL => unreachable,
                    .FAULT => unreachable,
                    .AGAIN => return error.WouldBlock,
                    .BADF => return error.NotOpenForWriting,
                    .IO => return error.InputOutput,
                    .NOBUFS => return error.SystemResources,
                    .NOMEM => return error.SystemResources,
                    .NOTCONN => return error.ConnectionResetByPeer,
                    .CONNRESET => return error.ConnectionResetByPeer,
                    .TIMEDOUT => return error.ConnectionResetByPeer,
                    else => unreachable,
                }
            },
            SSL_ERROR.SSL => return error.SSLProtocolError,
        }
    }
}
