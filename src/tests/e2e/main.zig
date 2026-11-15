const std = @import("std");
const runtime_io = @import("runtime_io");

const consts = @import("consts.zig");

const server = @import("server");
const SecureStream = server.Stream.StreamT(true);
const Stream = server.Stream.StreamT(false);

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

fn readResponse(socket: anytype) ![]const u8 {
    var buffer: [1025]u8 = undefined;
    var reader = socket.reader(&buffer);
    const response = reader.interface.takeDelimiterInclusive(consts.EXT_CHAR) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        else => return err,
    };
    return std.heap.page_allocator.dupe(u8, response[0 .. response.len - 1]);
}

fn sendAndExpect(socket: anytype, command: []const u8, label: []const u8, expected: []const u8, reverse: bool) !void {
    try socket.writeAll(command);
    const response = try readResponse(socket);
    defer std.heap.page_allocator.free(response);

    const raw = try repr(std.heap.page_allocator, response);
    defer std.heap.page_allocator.free(raw);
    const is_equal = !std.mem.eql(u8, response, expected);

    if (reverse != is_equal) {
        // reverse == true → expecting NOT equal → failed if is_equal == true
        // reverse == false → expecting equal → failed if is_equal == false
        const raw_expected = try repr(std.heap.page_allocator, expected);
        defer std.heap.page_allocator.free(raw_expected);
        failed += 1;

        std.debug.print("{s}x{s}\r\n", .{ red, reset });
        std.debug.print("[FAIL] {s}: got '{s}', expected {s} '{s}'\n", .{ label, raw, if (reverse) "not" else "", raw_expected });
    } else {
        std.debug.print("{s}.{s}", .{ green, reset });
        passed += 1;
    }
}

fn send(socket: anytype, command: []const u8) ![]const u8 {
    try socket.writeAll(command);
    return readResponse(socket);
}

fn expectBytes(socket: anytype, label: []const u8, expected: []const u8) !void {
    const allocator = std.heap.page_allocator;
    const response = try allocator.alloc(u8, expected.len);
    defer allocator.free(response);

    var received: usize = 0;
    var frames: usize = 0;
    const expected_frames = std.mem.count(u8, expected, &.{consts.EXT_CHAR});
    while (received < response.len) {
        const n = try socket.read(response[received..]);
        if (n == 0) {
            failed += 1;
            std.debug.print("{s}x{s}\n[FAIL] {s}: EOF after {d} of {d} bytes\n", .{ red, reset, label, received, expected.len });
            return error.UnexpectedResponseEof;
        }
        frames += std.mem.count(u8, response[received .. received + n], &.{consts.EXT_CHAR});
        received += n;
        if (frames >= expected_frames) break;
    }

    if (received != expected.len or !std.mem.eql(u8, response, expected)) {
        failed += 1;
        std.debug.print("{s}x{s}\n[FAIL] {s}: response differs ({d} bytes, expected {d})\n", .{ red, reset, label, received, expected.len });
        return error.ResponseMismatch;
    }
    passed += 1;
    std.debug.print("{s}.{s}", .{ green, reset });
}

fn testNetworkRegressions(socket: anytype) !void {
    try socket.writeAll("*1\r\n$4\r\nPI");
    runtime_io.sleepNanoseconds(50_000_000);
    try socket.writeAll("NG\r\n\x03*1\r\n$4\r\nPING\r\n\x03");
    try expectBytes(socket, "fragmented and pipelined PING", "+PONG\r\n\x03+PONG\r\n\x03");

    const allocator = std.heap.page_allocator;
    const payload = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(payload);
    const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789";
    for (payload, 0..) |*byte, i| byte.* = alphabet[i % alphabet.len];

    const set_command = try std.fmt.allocPrint(
        allocator,
        "*3\r\n$3\r\nSET\r\n$8\r\nlargekey\r\n${d}\r\n{s}\r\n\x03",
        .{ payload.len, payload },
    );
    defer allocator.free(set_command);
    try socket.writeAll(set_command);
    try expectBytes(socket, "large SET", "+OK\r\n\x03");

    const expected = try std.fmt.allocPrint(allocator, "${d}\r\n{s}\r\n\x03", .{ payload.len, payload });
    defer allocator.free(expected);
    try socket.writeAll("*2\r\n$3\r\nGET\r\n$8\r\nlargekey\r\n\x03");
    try expectBytes(socket, "large GET", expected);
}

pub fn runServer(tls: bool) !std.process.Child {
    var argv = [_][]const u8{"./zig-out/bin/zcached"};
    if (tls) {
        argv = [_][]const u8{"./zig-out/bin/zcached_tls"};
    }
    const child = try std.process.spawn(runtime_io.get(), .{ .argv = &argv });

    // std.debug.print("Server started with PID: {}, TLS: {}\n", .{ child.id, tls });

    runtime_io.sleepNanoseconds(1_000_000_000);

    return child;
}

pub fn connectSecure() !SecureStream {
    var socket = try connectUnsecure(SecureStream);
    errdefer socket.close();

    socket.ctx = try server.secure.upgradeClient(socket.io, socket.socket);
    return socket;
}

pub fn connectUnsecure(T: type) !T {
    const address = try std.Io.net.IpAddress.parse(consts.HOST, consts.PORT);
    const io = runtime_io.get();
    const connected = try address.connect(io, .{ .mode = .stream });
    return .{ .io = io, .socket = connected };
}

fn stopServer(child: *std.process.Child) !std.process.Child.Term {
    const pid = child.id orelse return error.ChildAlreadyWaited;
    try std.posix.kill(pid, .TERM);
    return child.wait(runtime_io.get());
}

pub fn main() !u8 {
    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded_io.deinit();
    runtime_io.runtime = threaded_io.io();

    var server_process = try runServer(false);
    errdefer if (server_process.id != null) {
        _ = stopServer(&server_process) catch |err| {
            std.debug.print("Failed to stop server: {s}\n", .{@errorName(err)});
        };
    };

    var unsecure_stream = try connectUnsecure(Stream);
    defer unsecure_stream.close();

    try runTests(&unsecure_stream);
    try testNetworkRegressions(&unsecure_stream);

    var term = try stopServer(&server_process);

    // For now it means memory leak or crash
    if (term != .exited or term.exited != 0) std.process.exit(1);

    var secure_server_process = try runServer(true);
    errdefer if (secure_server_process.id != null) {
        _ = stopServer(&secure_server_process) catch |err| {
            std.debug.print("Failed to stop secure server: {s}\n", .{@errorName(err)});
        };
    };

    var idle_connections: [4]Stream = undefined;
    var idle_count: usize = 0;
    defer {
        for (idle_connections[0..idle_count]) |*connection| connection.close();
    }
    while (idle_count < idle_connections.len) : (idle_count += 1) {
        idle_connections[idle_count] = try connectUnsecure(Stream);
    }

    var secure_stream = try connectSecure();
    defer secure_stream.close();

    try runTests(&secure_stream);
    try testNetworkRegressions(&secure_stream);

    term = try stopServer(&secure_server_process);
    // For now it means memory leak or crash
    if (term != .exited or term.exited != 0) std.process.exit(1);

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

    runtime_io.sleepNanoseconds(1000000000); // Wait for a second to ensure LASTSAVE changes

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
