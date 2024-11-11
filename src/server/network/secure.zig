const std = @import("std");

const openssl = @cImport({
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/err.h");
});

const builtin = @import("builtin");
const native_os = builtin.os.tag;
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

    pub fn init(key: []const u8, cert: []const u8) !Context {
        const ctx: *openssl.SSL_CTX = openssl.SSL_CTX_new(openssl.TLS_server_method()) orelse {
            return error.SSLContextFailure;
        };
        errdefer openssl.SSL_CTX_free(ctx);

        if (openssl.SSL_CTX_set_min_proto_version(
            ctx,
            openssl.TLS1_2_VERSION,
        ) != OPENSSL_SUCCESS) {
            return error.SSLMinVersion;
        }

        var buffer: [std.posix.PATH_MAX]u8 = undefined;
        var key_buffer: [std.posix.PATH_MAX]u8 = undefined;
        const certz: [:0]u8 = try std.fmt.bufPrintZ(&buffer, "{s}", .{cert});
        const keyz: [:0]u8 = try std.fmt.bufPrintZ(&key_buffer, "{s}", .{key});

        openssl.SSL_CTX_set_info_callback(ctx, ssl_info_callback);
        openssl.SSL_CTX_set_verify(ctx, openssl.SSL_VERIFY_NONE, null);

        _ = openssl.SSL_CTX_set_mode(ctx, openssl.SSL_MODE_AUTO_RETRY);

        if (openssl.SSL_CTX_use_certificate_file(
            ctx,
            certz.ptr,
            openssl.SSL_FILETYPE_PEM,
        ) != OPENSSL_SUCCESS) {
            print_ssl_error();
            return error.CertFailure;
        }

        if (openssl.SSL_CTX_use_PrivateKey_file(
            ctx,
            keyz.ptr,
            openssl.SSL_FILETYPE_PEM,
        ) != OPENSSL_SUCCESS) {
            print_ssl_error();
            return error.KeyFailure;
        }

        if (openssl.SSL_CTX_check_private_key(ctx) != OPENSSL_SUCCESS) {
            print_ssl_error();
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
            const rc: i32 = @intCast(openssl.SSL_get_error(ctx, return_code));
            std.debug.print("{any}\n", .{rc});
            openssl.SSL_free(ctx);
            return error.SSLSetFdFailure;
        }

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

        stream.ctx = StreamContext{ .ctx = ctx };
    }

    pub fn deinit(self: *Context) void {
        _ = self;
        // openssl.SSL_CTX_free(self.ctx);
    }
};

pub const StreamContext = struct {
    ctx: *openssl.SSL = undefined,

    pub fn deinit(self: StreamContext) void {
        _ = openssl.SSL_shutdown(self.ctx);
        openssl.SSL_free(self.ctx);
    }
};

fn ssl_info_callback(ssl: ?*const openssl.SSL, t: c_int, v: c_int) callconv(.C) void {
    _ = ssl;
    _ = t;

    var timestamp: [40]u8 = undefined;
    const t_size = utils.timestampf(&timestamp);
    std.debug.print(
        "INFO [{s}] SSL_info callback: type={any}, val={any}\n",
        .{ timestamp[0..t_size], type, v },
    );
}

pub fn print_ssl_error() void {
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

pub fn ssl_read(ctx: ?*openssl.SSL, buffer: []u8) !usize {
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

pub fn ssl_write(ctx: ?*openssl.SSL, buffer: []const u8) !usize {
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
            SSL_ERROR.SYSCALL => |err| {
                // System-level error encountered, return specific system errors
                switch (std.posix.errno(@intFromEnum(err))) {
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
