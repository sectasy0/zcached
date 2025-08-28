const std = @import("std");
const builtin = @import("builtin");

const consts = @import("consts.zig");

const server = @import("server");
const network = server.network;
const openssl = network.secure.openssl;
const SecureStream = network.Stream.StreamT(network.secure);
const Stream = network.Stream.StreamT(network.unsecure);

var passed: usize = 0;
var failed: usize = 0;

const green = "\x1b[32m";
const red = "\x1b[31m";
const reset = "\x1b[0m";

// Converts the provided byte array representing protocol raw data to its string
// representation by replacing occurrences of "\r\n" with "\\r\\n".
fn repr(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const size = std.mem.replacementSize(u8, value, "\r\n", "\\r\\n");
    const output = try allocator.alloc(u8, size);
    _ = std.mem.replace(u8, value, "\r\n", "\\r\\n", output);
    return output;
}

fn sendAndExpect(socket: anytype, command: []const u8, label: []const u8, expected: []const u8, reverse: bool) !void {
    _ = try socket.writeAll(@constCast(command));
    std.time.sleep(100_0000); // Give the server some time to respond
    const response = try socket.reader().readUntilDelimiterAlloc(
        std.heap.page_allocator,
        consts.EXT_CHAR,
        1024,
    );
    defer std.heap.page_allocator.free(response);

    const raw = try repr(std.heap.page_allocator, response);
    const is_equal = !std.mem.eql(u8, response, expected);

    if (reverse != is_equal) {
        // reverse == true → expecting NOT equal → failed if is_equal == true
        // reverse == false → expecting equal → failed if is_equal == false
        const raw_expected = try repr(std.heap.page_allocator, expected);
        failed += 1;

        std.debug.print("{s}x{s}\r\n", .{ red, reset });
        std.debug.print("[FAIL] {s}: got '{s}', expected {s} '{s}'\n", .{ label, raw, if (reverse) "not" else "", raw_expected });
    } else {
        std.debug.print("{s}.{s}", .{ green, reset });
        passed += 1;
    }
}

fn send(socket: anytype, command: []const u8) ![]const u8 {
    _ = try socket.writeAll(@constCast(command));
    const response = try socket.reader().readUntilDelimiterAlloc(
        std.heap.page_allocator,
        consts.EXT_CHAR,
        1024,
    );

    return response;
}

pub fn runServer(tls: bool) !std.process.Child {
    var argv = [_][]const u8{"./zig-out/bin/zcached"};
    if (tls) {
        argv = [_][]const u8{"./zig-out/bin/zcached_tls"};
    }
    var child = std.process.Child.init(&argv, std.heap.page_allocator);
    // child.stderr_behavior = .Ignore;
    // child.stdout_behavior = .Ignore;
    try child.spawn();
    std.time.sleep(100000_000); // Give the server some time to start

    // std.debug.print("Server started with PID: {}, TLS: {}\n", .{ child.id, tls });

    return child;
}

pub fn connectSecure() !SecureStream {
    var socket = try connectUnsecure(SecureStream);
    errdefer socket.close();

    const ctx = openssl.SSL_CTX_new(openssl.TLS_client_method());
    if (ctx == null) return error.SSLContextCreationFailed;

    _ = openssl.SSL_CTX_set_min_proto_version(ctx, openssl.TLS1_3_VERSION);
    // openssl.SSL_CTX_set_info_callback(ctx, ssl_info_callback);

    const ssl = openssl.SSL_new(ctx);
    if (ssl == null) {
        openssl.SSL_CTX_free(ctx);
        return error.SSLCreationFailed;
    }

    _ = openssl.SSL_CTX_set_mode(ctx, openssl.SSL_MODE_AUTO_RETRY);
    openssl.SSL_set_verify(ssl, openssl.SSL_VERIFY_NONE, null);

    const return_code = openssl.SSL_set_fd(ssl, socket.handle);
    if (return_code == 0) {
        const rc: i32 = @intCast(openssl.SSL_get_error(ssl, return_code));
        std.debug.print("SSL_set_fd failed with error code: {d}\n", .{rc});
        openssl.SSL_free(ssl);
        return error.SSLSetFdFailure;
    }

    if (openssl.SSL_connect(ssl) <= 0) {
        openssl.SSL_free(ssl);
        openssl.SSL_CTX_free(ctx);
        return error.SSLConnectFailed;
    }

    socket.ctx = .{ .ctx = ssl };

    return socket;
}

pub fn connectUnsecure(T: type) !T {
    const address = try std.net.Address.parseIp(consts.HOST, consts.PORT);
    const nonblock = 0;
    const sock_flags = std.posix.SOCK.STREAM | nonblock |
        (if (builtin.os.tag == .windows) 0 else std.posix.SOCK.CLOEXEC);

    const sockfd = try std.posix.socket(address.any.family, sock_flags, std.posix.IPPROTO.TCP);
    errdefer T.close(@constCast(&T{ .handle = sockfd, .ctx = null }));

    try std.posix.connect(sockfd, &address.any, address.getOsSockLen());

    return .{ .handle = sockfd, .ctx = null };
}

pub fn main() !u8 {
    var server_process = try runServer(false);

    var unsecure_stream = try connectUnsecure(Stream);
    defer unsecure_stream.close();

    try runTests(unsecure_stream);

    _ = server_process.kill() catch |err| {
        std.debug.print("Failed to kill server process: {}\n", .{err});
    };

    var term = try server_process.wait();

    // For now it means memory leak or crash
    if (term.Exited != 0) std.process.exit(1);

    var secure_server_process = try runServer(true);
    var secure_stream = try connectSecure();
    defer secure_stream.close();

    errdefer {
        _ = secure_server_process.kill() catch |err| {
            std.debug.print("Failed to kill secure server process: {}\n", .{err});
        };
    }

    try runTests(secure_stream);

    _ = secure_server_process.kill() catch |err| {
        std.debug.print("Failed to kill secure server process: {}\n", .{err});
    };

    term = try secure_server_process.wait();
    // For now it means memory leak or crash
    if (term.Exited != 0) std.process.exit(1);

    if (failed > 0) {
        std.debug.print("\n[SUMMARY] Test suite completed: {d} passed, {d} failed.\n", .{ passed, failed });
        return 1; // Indicate failure
    } else {
        std.debug.print("\n[SUMMARY] Test suite completed successfully: all {d} tests passed.\n", .{passed});
        return 0; // Indicate success
    }
}

fn runTests(socket: anytype) !void {
    // send ping command
    try sendAndExpect(
        socket,
        "*1\r\n$4\r\nPING\r\n\x03",
        "PING",
        "+PONG\r\n",
        false,
    );

    try sendAndExpect(
        socket,
        "*3\r\n$3\r\nSET\r\n$9\r\nmycounter\r\n:42\r\n\x03",
        "SET mycounter",
        "+OK\r\n",
        false,
    );

    try sendAndExpect(
        socket,
        "*2\r\n$3\r\nGET\r\n$9\r\nmycounter\r\n\x03",
        "GET mycounter",
        ":42\r\n",
        false,
    );

    try deleteAndGet(socket);
    try flushAndGet(socket);
    try mgetAndMset(socket);

    try dbsizeAndDelete(socket);
    try save(socket);
    try sizeOf(socket);
    try rename(socket);

    try testAdditionalTypes(socket);
}

fn deleteAndGet(socket: anytype) !void {
    try sendAndExpect(
        socket,
        "*2\r\n$6\r\nDELETE\r\n$9\r\nmycounter\r\n\x03",
        "DELETE mycounter",
        "+OK\r\n",
        false,
    );

    // try to get deleted key
    try sendAndExpect(
        socket,
        "*2\r\n$3\r\nGET\r\n$9\r\nmycounter\r\n\x03",
        "GET mycounter after DELETE",
        "-ERR 'mycounter' not found\r\n",
        false,
    );
}

fn flushAndGet(socket: anytype) !void {
    try sendAndExpect(
        socket,
        "*3\r\n$3\r\nSET\r\n$9\r\nmycounter\r\n:42\r\n\x03",
        "SET mycounter",
        "+OK\r\n",
        false,
    );

    try sendAndExpect(
        socket,
        "*1\r\n$5\r\nFLUSH\r\n\x03",
        "FLUSH",
        "+OK\r\n",
        false,
    );

    // try to get deleted key
    try sendAndExpect(
        socket,
        "*2\r\n$3\r\nGET\r\n$9\r\nmycounter\r\n\x03",
        "GET mycounter after FLUSH",
        "-ERR 'mycounter' not found\r\n",
        false,
    );
}

fn mgetAndMset(socket: anytype) !void {
    // MSET multiple keys
    try sendAndExpect(
        socket,
        "*7\r\n$4\r\nMSET\r\n$4\r\nkey1\r\n:1\r\n$4\r\nkey2\r\n:2\r\n$4\r\nkey3\r\n:3\r\n\x03",
        "MSET multiple keys",
        "+OK\r\n",
        false,
    );

    // MGET multiple keys
    try sendAndExpect(
        socket,
        "*4\r\n$4\r\nMGET\r\n$4\r\nkey1\r\n$4\r\nkey2\r\n$4\r\nkey3\r\n\x03",
        "MGET multiple keys",
        "%3\r\n$4\r\nkey1\r\n:1\r\n$4\r\nkey2\r\n:2\r\n$4\r\nkey3\r\n:3\r\n",
        false,
    );
}

fn dbsizeAndDelete(socket: anytype) !void {
    // DBSIZE command
    try sendAndExpect(
        socket,
        "*1\r\n$6\r\nDBSIZE\r\n\x03",
        "DBSIZE",
        ":3\r\n",
        false,
    );

    // DELETE command
    try sendAndExpect(
        socket,
        "*2\r\n$6\r\nDELETE\r\n$4\r\nkey1\r\n\x03",
        "DELETE key1",
        "+OK\r\n",
        false,
    );

    // Check DBSIZE again
    try sendAndExpect(
        socket,
        "*1\r\n$6\r\nDBSIZE\r\n\x03",
        "DBSIZE after DELETE",
        ":2\r\n",
        false,
    );

    // ECHO
    try sendAndExpect(
        socket,
        "*2\r\n$4\r\nECHO\r\n$5\r\nHello\r\n\x03",
        "ECHO Hello",
        "$5\r\nHello\r\n",
        false,
    );
}

fn save(socket: anytype) !void {
    const save_response = try send(socket, "*1\r\n$8\r\nLASTSAVE\r\n\x03");
    defer std.heap.page_allocator.free(save_response);

    try sendAndExpect(
        socket,
        "*1\r\n$8\r\nLASTSAVE\r\n\x03",
        "LASTSAVE before SAVE",
        save_response,
        false,
    );

    // set something
    try sendAndExpect(
        socket,
        "*3\r\n$3\r\nSET\r\n$9\r\nmycounter\r\n:42\r\n\x03",
        "SET mycounter before SAVE",
        "+OK\r\n",
        false,
    );

    std.time.sleep(1000000000); // Wait for a second to ensure LASTSAVE changes

    // SAVE command
    try sendAndExpect(
        socket,
        "*1\r\n$4\r\nSAVE\r\n\x03",
        "SAVE",
        "+OK\r\n",
        false,
    );

    // Check LASTSAVE
    try sendAndExpect(
        socket,
        "*1\r\n$8\r\nLASTSAVE\r\n\x03",
        "LASTSAVE different after SAVE",
        save_response,
        true,
    );
}

fn sizeOf(socket: anytype) !void {
    // SET some keys to test SIZEOF
    try sendAndExpect(
        socket,
        "*3\r\n$3\r\nSET\r\n$4\r\nkey1\r\n:42\r\n\x03",
        "SET key1",
        "+OK\r\n",
        false,
    );
    // SIZEOF command
    try sendAndExpect(
        socket,
        "*2\r\n$6\r\nSIZEOF\r\n$4\r\nkey1\r\n\x03",
        "SIZEOF key1",
        ":8\r\n",
        false,
    );

    // Check SIZEOF for a non-existing key
    try sendAndExpect(
        socket,
        "*2\r\n$6\r\nSIZEOF\r\n$11\r\nnonexistent\r\n\x03",
        "SIZEOF nonexistent",
        "-ERR 'nonexistent' not found\r\n",
        false,
    );
}

fn rename(socket: anytype) !void {
    // RENAME command
    try sendAndExpect(
        socket,
        "*3\r\n$6\r\nRENAME\r\n$4\r\nkey1\r\n$7\r\nnewkey1\r\n\x03",
        "RENAME key1 to newkey1",
        "+OK\r\n",
        false,
    );

    // Check if the key was renamed
    try sendAndExpect(
        socket,
        "*2\r\n$3\r\nGET\r\n$7\r\nnewkey1\r\n\x03",
        "GET newkey1 after RENAME",
        ":42\r\n",
        false,
    );

    // Check if the old key no longer exists
    try sendAndExpect(
        socket,
        "*2\r\n$3\r\nGET\r\n$4\r\nkey1\r\n\x03",
        "GET key1 after RENAME",
        "-ERR 'key1' not found\r\n",
        false,
    );
}

fn copy(socket: anytype) !void {
    // COPY command
    try sendAndExpect(
        socket,
        "*3\r\n$4\r\nCOPY\r\n$4\r\nkey1\r\n$7\r\nnewkey1\r\n\x03",
        "COPY key1 to newkey1",
        "+OK\r\n",
        false,
    );

    // Check if the new key exists
    try sendAndExpect(
        socket,
        "*2\r\n$3\r\nGET\r\n$7\r\nnewkey1\r\n\x03",
        "GET newkey1 after COPY",
        ":42\r\n",
        false,
    );
}

/// Tests additional types like float, boolean, null, array, and map.
/// This function sends commands to the server and expects specific responses.
/// It includes tests for setting and getting these types, as well as checking their sizes.
/// It also tests the deletion of these types and ensures that the server responds correctly.
/// The function uses the `sendAndExpect` utility to send commands and check responses.
/// It is designed to be run as part of the server's end-to-end tests.
fn testAdditionalTypes(socket: anytype) !void {
    // Float test
    try sendAndExpect(
        socket,
        "*3\r\n$3\r\nSET\r\n$5\r\nfloat\r\n,3.1415\r\n\x03",
        "SET float",
        "+OK\r\n",
        false,
    );
    try sendAndExpect(
        socket,
        "*2\r\n$3\r\nGET\r\n$5\r\nfloat\r\n\x03",
        "GET float",
        ",3.1415\r\n",
        false,
    );
    try sendAndExpect(
        socket,
        "*2\r\n$6\r\nSIZEOF\r\n$5\r\nfloat\r\n\x03",
        "GET float SIZEOF",
        ":8\r\n",
        false,
    );
    try sendAndExpect(
        socket,
        "*2\r\n$6\r\nDELETE\r\n$5\r\nfloat\r\n\x03",
        "DELETE float",
        "+OK\r\n",
        false,
    );

    // Boolean test: true
    try sendAndExpect(
        socket,
        "*3\r\n$3\r\nSET\r\n$4\r\nbool\r\n#t\r\n\x03",
        "SET bool true",
        "+OK\r\n",
        false,
    );
    try sendAndExpect(
        socket,
        "*2\r\n$3\r\nGET\r\n$4\r\nbool\r\n\x03",
        "GET bool",
        "#t\r\n",
        false,
    );
    try sendAndExpect(
        socket,
        "*2\r\n$6\r\nSIZEOF\r\n$4\r\nbool\r\n\x03",
        "GET bool SIZEOF",
        ":1\r\n",
        false,
    );
    try sendAndExpect(
        socket,
        "*2\r\n$6\r\nDELETE\r\n$4\r\nbool\r\n\x03",
        "DELETE bool",
        "+OK\r\n",
        false,
    );

    // Null test
    try sendAndExpect(
        socket,
        "*3\r\n$3\r\nSET\r\n$7\r\nnullkey\r\n_\r\n\x03",
        "SET null",
        "+OK\r\n",
        false,
    );
    try sendAndExpect(
        socket,
        "*2\r\n$3\r\nGET\r\n$7\r\nnullkey\r\n\x03",
        "GET nullkey",
        "_\r\n",
        false,
    );
    try sendAndExpect(
        socket,
        "*2\r\n$6\r\nSIZEOF\r\n$7\r\nnullkey\r\n\x03",
        "GET nullkey SIZEOF",
        ":0\r\n",
        false,
    );
    try sendAndExpect(
        socket,
        "*2\r\n$6\r\nDELETE\r\n$7\r\nnullkey\r\n\x03",
        "DELETE nullkey",
        "+OK\r\n",
        false,
    );
    try sendAndExpect(
        socket,
        "*2\r\n$3\r\nGET\r\n$7\r\nnullkey\r\n\x03",
        "GET nullkey after DELETE",
        "-ERR 'nullkey' not found\r\n",
        false,
    );

    // Array test
    try sendAndExpect(
        socket,
        "*3\r\n$3\r\nSET\r\n$5\r\narray\r\n*1\r\n$4\r\nitem\r\n\x03",
        "SET array",
        "+OK\r\n",
        false,
    );
    try sendAndExpect(
        socket,
        "*2\r\n$3\r\nGET\r\n$5\r\narray\r\n\x03",
        "GET array",
        "*1\r\n$4\r\nitem\r\n",
        false,
    );
    try sendAndExpect(
        socket,
        "*2\r\n$6\r\nSIZEOF\r\n$5\r\narray\r\n\x03",
        "GET array SIZEOF",
        ":1\r\n",
        false,
    );
    try sendAndExpect(
        socket,
        "*2\r\n$6\r\nDELETE\r\n$5\r\narray\r\n\x03",
        "DELETE array",
        "+OK\r\n",
        false,
    );
    try sendAndExpect(
        socket,
        "*2\r\n$3\r\nGET\r\n$5\r\narray\r\n\x03",
        "GET array after DELETE",
        "-ERR 'array' not found\r\n",
        false,
    );

    // Map test
    try sendAndExpect(
        socket,
        "*3\r\n$3\r\nSET\r\n$3\r\nmap\r\n%2\r\n$4\r\nkey1\r\n$6\r\nvalue1\r\n$4\r\nkey2\r\n$6\r\nvalue2\r\n\x03",
        "SET map",
        "+OK\r\n",
        false,
    );
    try sendAndExpect(
        socket,
        "*2\r\n$3\r\nGET\r\n$3\r\nmap\r\n\x03",
        "GET map",
        "%2\r\n$4\r\nkey1\r\n$6\r\nvalue1\r\n$4\r\nkey2\r\n$6\r\nvalue2\r\n",
        false,
    );
    try sendAndExpect(
        socket,
        "*2\r\n$6\r\nSIZEOF\r\n$3\r\nmap\r\n\x03",
        "GET map SIZEOF",
        ":2\r\n",
        false,
    );
    try sendAndExpect(
        socket,
        "*2\r\n$6\r\nDELETE\r\n$3\r\nmap\r\n\x03",
        "DELETE map",
        "+OK\r\n",
        false,
    );
    try sendAndExpect(
        socket,
        "*2\r\n$3\r\nGET\r\n$3\r\nmap\r\n\x03",
        "GET map after DELETE",
        "-ERR 'map' not found\r\n",
        false,
    );
}

export fn ssl_info_callback(ssl: ?*const openssl.SSL, t: c_int, v: c_int) callconv(.C) void {
    const t_str = switch (t) {
        openssl.SSL_CB_LOOP => "LOOP",
        openssl.SSL_CB_EXIT => "EXIT",
        openssl.SSL_CB_READ => "READ",
        openssl.SSL_CB_WRITE => "WRITE",
        openssl.SSL_CB_ALERT => "ALERT",
        openssl.SSL_CB_READ_ALERT => "READ_ALERT",
        openssl.SSL_CB_WRITE_ALERT => "WRITE_ALERT",
        openssl.SSL_CB_HANDSHAKE_START => "HANDSHAKE_START",
        openssl.SSL_CB_HANDSHAKE_DONE => "HANDSHAKE_DONE",
        else => "UNKNOWN",
    };

    const v_str = if (v == 0) "0" else if (v == 1) "1" else "OTHER";

    if (ssl) |ssl_ptr| {
        std.debug.print("INFO [SSL {x}] SSL_info callback: type={s}, val={s}\n", .{ ssl_ptr, t_str, v_str });
    } else {
        std.debug.print("INFO [SSL NULL] SSL_info callback: type={s}, val={s}\n", .{ t_str, v_str });
    }
}
