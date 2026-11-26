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

fn runServer(tls: bool, config_path: ?[]const u8, log_path: ?[]const u8) !std.process.Child {
    const argv = [_][]const u8{
        if (tls) "./zig-out/bin/zcached_tls" else "./zig-out/bin/zcached",
        "--config-path",
        config_path orelse "",
        "--log-path",
        log_path orelse "",
    };
    const child = try std.process.spawn(runtime_io.get(), .{ .argv = if (config_path != null) &argv else argv[0..1] });

    // std.debug.print("Server started with PID: {}, TLS: {}\n", .{ child.id, tls });

    runtime_io.sleepNanoseconds(1_000_000_000);

    return child;
}

fn createE2EConfig(path: []const u8, tls: bool) !void {
    const io = runtime_io.get();
    var config_buf: [1536]u8 = undefined;
    const config = if (tls)
        try std.fmt.bufPrint(
            &config_buf,
            \\.{{
            \\    .address = "{s}", .port = {d}, .workers = 2,
            \\    .tls = .{{
            \\        .enabled = true,
            \\        .cert_path = "./src/tests/e2e/certificate.pem",
            \\        .key_path = "./src/tests/e2e/private_key.pem",
            \\        .verify_mode = .none,
            \\    }},
            \\    .log_network_payloads = false,
            \\    .snapshot = .{{ .path = "{s}/snapshots" }},
            \\    .aof = .{{ .flush_strategy = .no, .path = "{s}/appendonly.aof" }},
            \\    .whitelist = .{{ "{s}" }},
            \\}}
        ,
            .{ consts.HOST, consts.PORT, path, path, consts.HOST },
        )
    else
        try std.fmt.bufPrint(
            &config_buf,
            \\.{{
            \\    .address = "{s}", .port = {d}, .workers = 2,
            \\    .tls = .{{ .enabled = false }},
            \\    .log_network_payloads = false,
            \\    .snapshot = .{{ .path = "{s}/snapshots" }},
            \\    .aof = .{{ .flush_strategy = .no, .path = "{s}/appendonly.aof" }},
            \\    .whitelist = .{{ "{s}" }},
            \\}}
        ,
            .{ consts.HOST, consts.PORT, path, path, consts.HOST },
        );

    var config_path_buf: [96]u8 = undefined;
    const config_path = try std.fmt.bufPrint(&config_path_buf, "{s}/config.zon", .{path});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = config_path, .data = config });
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

    const cwd = std.Io.Dir.cwd();
    var path_buf: [80]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zcached-e2e-main-{d}", .{runtime_io.timestampNanoseconds()});
    try cwd.createDir(runtime_io.get(), path, .default_dir);
    defer cwd.deleteTree(runtime_io.get(), path) catch |err| {
        std.debug.print("\nFailed to clean up {s}: {s}\n", .{ path, @errorName(err) });
    };
    try createE2EConfig(path, false);

    var config_path_buf: [112]u8 = undefined;
    var log_path_buf: [112]u8 = undefined;
    const config_path = try std.fmt.bufPrint(&config_path_buf, "{s}/config.zon", .{path});
    const log_path = try std.fmt.bufPrint(&log_path_buf, "{s}/server.log", .{path});
    var server_process = try runServer(false, config_path, log_path);
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

    try createE2EConfig(path, true);
    var secure_server_process = try runServer(true, config_path, log_path);
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

    try testExpiryRecovery(.snapshot);
    try testExpiryRecovery(.aof);
    try testCrashRecovery(.snapshot);
    try testCrashRecovery(.aof);

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

    try expectCommand(socket, &.{ "COMMAND", "COUNT" }, "COMMAND COUNT", ":26\r\n");
    try expectCommand(socket, &.{ "CLIENT", "ID" }, "CLIENT ID", ":0\r\n");

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
    try testExpiry(socket);
}

fn encodeCommand(comptime args: []const []const u8) []const u8 {
    return comptime blk: {
        var frame: []const u8 = std.fmt.comptimePrint("*{d}\r\n", .{args.len});
        for (args) |arg| frame = frame ++ std.fmt.comptimePrint("${d}\r\n{s}\r\n", .{ arg.len, arg });
        break :blk frame ++ "\x03";
    };
}

fn expectCommand(socket: anytype, comptime args: []const []const u8, label: []const u8, expected: []const u8) !void {
    try sendAndExpect(socket, encodeCommand(args), label, expected, false);
}

fn readTtl(socket: anytype, comptime key: []const u8) !i64 {
    const response = try send(socket, encodeCommand(&.{ "TTL", key }));
    defer std.heap.page_allocator.free(response);
    if (!std.mem.startsWith(u8, response, ":") or !std.mem.endsWith(u8, response, "\r\n")) {
        std.debug.print("\n[FAIL] TTL {s}: expected an integer reply, got '{s}'\n", .{ key, response });
        return error.ResponseMismatch;
    }
    return std.fmt.parseInt(i64, response[1 .. response.len - 2], 10);
}

fn expectTtlRange(socket: anytype, comptime key: []const u8, min: i64, max: i64) !void {
    const ttl = try readTtl(socket, key);
    if (ttl < min or ttl > max) {
        std.debug.print("\n[FAIL] TTL {s}: got {d}, expected {d}..{d}\n", .{ key, ttl, min, max });
        return error.ResponseMismatch;
    }
    passed += 1;
    std.debug.print("{s}.{s}", .{ green, reset });
}

fn testExpiry(socket: anytype) !void {
    try expectCommand(socket, &.{"FLUSH"}, "clear state before TTL tests", "+OK\r\n");
    try expectCommand(socket, &.{ "TTL", "src" }, "TTL missing key", ":-2\r\n");
    try expectCommand(socket, &.{ "EXPIRE", "src", "60" }, "EXPIRE missing key", ":0\r\n");
    try expectCommand(socket, &.{ "PERSIST", "src" }, "PERSIST missing key", ":0\r\n");
    try expectCommand(socket, &.{ "SET", "src", "value", "EX", "60" }, "SET with seconds", "+OK\r\n");
    try expectTtlRange(socket, "src", 55, 60);
    try expectCommand(socket, &.{ "SET", "src", "changed", "PX", "0" }, "zero SET expiry is rejected", "-INVALID_EXPIRY\r\n");
    try expectCommand(socket, &.{ "SET", "src", "changed", "EX", "9223372036854775807" }, "overflowing SET expiry is rejected", "-INVALID_EXPIRY\r\n");
    try expectCommand(socket, &.{ "GET", "src" }, "rejected SET leaves the value unchanged", "$5\r\nvalue\r\n");
    try expectTtlRange(socket, "src", 55, 60);

    try expectCommand(socket, &.{ "EXPIRE", "src", "90" }, "EXPIRE changes the deadline", ":1\r\n");
    try expectTtlRange(socket, "src", 85, 90);
    try expectCommand(socket, &.{ "COPY", "src", "target" }, "COPY with TTL", "$2\r\nOK\r\n");
    try expectCommand(socket, &.{ "COPY", "src", "target" }, "COPY rejects an occupied target", "-BUSY_KEY\r\n");
    try expectCommand(socket, &.{ "RENAME", "target", "moved" }, "RENAME with TTL", "+OK\r\n");
    try expectTtlRange(socket, "moved", 85, 90);
    try expectCommand(socket, &.{ "TTL", "target" }, "TTL after RENAME removed the source", ":-2\r\n");
    try expectCommand(socket, &.{ "PERSIST", "moved" }, "PERSIST removes expiry", ":1\r\n");
    try expectCommand(socket, &.{ "PERSIST", "moved" }, "PERSIST on a persistent key", ":0\r\n");
    try expectCommand(socket, &.{ "TTL", "moved" }, "TTL persistent key", ":-1\r\n");
    try expectCommand(socket, &.{ "SET", "src", "value" }, "plain SET overwrites expiring key", "+OK\r\n");
    try expectCommand(socket, &.{ "TTL", "src" }, "plain SET clears TTL", ":-1\r\n");
    try expectCommand(socket, &.{ "EXPIRE", "src", "0" }, "EXPIRE zero deletes the key", ":1\r\n");
    try expectCommand(socket, &.{ "GET", "src" }, "GET after immediate expiry", "-NOT_FOUND\r\n");
    try expectCommand(socket, &.{ "EXPIRE", "moved", "60" }, "EXPIRE before MSET", ":1\r\n");
    try expectCommand(socket, &.{ "MSET", "moved", "value" }, "MSET overwrites expiring key", "+OK\r\n");
    try expectCommand(socket, &.{ "TTL", "moved" }, "MSET clears TTL", ":-1\r\n");
    try expectCommand(socket, &.{ "SET", "brief", "value", "PX", "60000" }, "SET with milliseconds", "+OK\r\n");
    try expectTtlRange(socket, "brief", 55, 60);

    try socket.writeAll(comptime encodeCommand(&.{ "SET", "brief", "value", "PX", "250" }) ++ encodeCommand(&.{"PING"}));
    try expectBytes(socket, "pipelined SET PX and PING", "+OK\r\n\x03+PONG\r\n\x03");
    const timeout = runtime_io.timestampNanoseconds() + 5 * std.time.ns_per_s;
    while (true) {
        const ttl = try readTtl(socket, "brief");
        if (ttl == -2) break;
        if (ttl != 0 or runtime_io.timestampNanoseconds() >= timeout) {
            std.debug.print("\n[FAIL] SET PX 250: expected a sub-second expiry, got TTL {d}\n", .{ttl});
            return error.ResponseMismatch;
        }
        runtime_io.sleepNanoseconds(20 * std.time.ns_per_ms);
    }
    try expectCommand(socket, &.{ "GET", "brief" }, "GET hides an expired key", "-NOT_FOUND\r\n");
    try expectCommand(socket, &.{ "MGET", "brief" }, "MGET returns null for an expired key", "%1\r\n$5\r\nbrief\r\n_\r\n");
    try expectCommand(socket, &.{"KEYS"}, "KEYS omits expired keys", "*1\r\n$5\r\nmoved\r\n");
    try expectCommand(socket, &.{"DBSIZE"}, "DBSIZE omits expired keys", ":1\r\n");
    try expectCommand(socket, &.{ "COPY", "moved", "brief" }, "COPY can reuse an expired destination", "$2\r\nOK\r\n");
    try expectCommand(socket, &.{ "TTL", "brief" }, "COPY replaces the old destination deadline", ":-1\r\n");
}

fn testExpiryRecovery(mode: enum { snapshot, aof }) !void {
    const io = runtime_io.get();
    const cwd = std.Io.Dir.cwd();
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zcached-e2e-{s}-{d}", .{ @tagName(mode), runtime_io.timestampNanoseconds() });
    try cwd.createDir(io, path, .default_dir);
    defer cwd.deleteTree(io, path) catch |err| {
        std.debug.print("\nFailed to clean up {s}: {s}\n", .{ path, @errorName(err) });
    };

    var config_path_buf: [96]u8 = undefined;
    var log_path_buf: [96]u8 = undefined;
    const config_path = try std.fmt.bufPrint(&config_path_buf, "{s}/config.zon", .{path});
    const log_path = try std.fmt.bufPrint(&log_path_buf, "{s}/server.log", .{path});
    var config_buf: [1024]u8 = undefined;
    const config = try std.fmt.bufPrint(&config_buf,
        \\.{{
        \\    .address = "{s}", .port = {d}, .workers = 2,
        \\    .tls = .{{ .enabled = false }},
        \\    .log_network_payloads = false,
        \\    .snapshot = .{{ .path = "{s}/snapshots" }},
        \\    .aof = .{{ .flush_strategy = .{s}, .path = "{s}/appendonly.aof" }},
        \\    .whitelist = .{{ "{s}" }},
        \\}}
    , .{ consts.HOST, consts.PORT, path, if (mode == .aof) "always" else "no", path, consts.HOST });
    try cwd.writeFile(io, .{ .sub_path = config_path, .data = config });

    std.debug.print("\n[{s} restart] ", .{@tagName(mode)});
    for (0..2) |boot| {
        var child = try runServer(false, config_path, log_path);
        errdefer if (child.id != null) {
            _ = stopServer(&child) catch |err| {
                std.debug.print("Failed to stop recovery server: {s}\n", .{@errorName(err)});
            };
        };
        {
            var socket = try connectUnsecure(Stream);
            defer socket.close();
            if (boot == 0) {
                try expectCommand(&socket, &.{ "SET", "live", "yes" }, "write key before restart", "+OK\r\n");
                try expectCommand(&socket, &.{ "EXPIRE", "live", "60" }, "set deadline before restart", ":1\r\n");
                try expectCommand(&socket, &.{ "SET", "keep", "yes", "EX", "60" }, "write key to persist", "+OK\r\n");
                try expectCommand(&socket, &.{ "PERSIST", "keep" }, "persist key before restart", ":1\r\n");
                try expectCommand(&socket, &.{ "SET", "offline", "yes", "EX", "3" }, "write key that expires offline", "+OK\r\n");
                try expectTtlRange(&socket, "offline", 1, 3);
                if (mode == .snapshot) try expectCommand(&socket, &.{"SAVE"}, "SAVE TTL snapshot", "+OK\r\n");
            } else {
                try expectCommand(&socket, &.{ "GET", "live" }, "live key survives restart", "$3\r\nyes\r\n");
                try expectTtlRange(&socket, "live", 1, 57);
                try expectCommand(&socket, &.{ "TTL", "keep" }, "PERSIST survives restart", ":-1\r\n");
                try expectCommand(&socket, &.{ "TTL", "offline" }, "offline expiry survives restart", ":-2\r\n");
                try expectCommand(&socket, &.{ "GET", "offline" }, "offline expiry is not resurrected", "-NOT_FOUND\r\n");
            }
        }
        const term = try stopServer(&child);
        if (term != .exited or term.exited != 0) return error.ServerExitedUncleanly;
        if (boot == 0) runtime_io.sleepNanoseconds(3 * std.time.ns_per_s);
    }
}

fn testCrashRecovery(mode: enum { snapshot, aof }) !void {
    const io = runtime_io.get();
    const cwd = std.Io.Dir.cwd();
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zcached-e2e-crash-{s}-{d}", .{ @tagName(mode), runtime_io.timestampNanoseconds() });
    try cwd.createDir(io, path, .default_dir);
    defer cwd.deleteTree(io, path) catch |err| {
        std.debug.print("\nFailed to clean up {s}: {s}\n", .{ path, @errorName(err) });
    };

    var config_path_buf: [128]u8 = undefined;
    var log_path_buf: [128]u8 = undefined;
    const config_path = try std.fmt.bufPrint(&config_path_buf, "{s}/config.zon", .{path});
    const log_path = try std.fmt.bufPrint(&log_path_buf, "{s}/server.log", .{path});
    var config_buf: [1024]u8 = undefined;
    const config = try std.fmt.bufPrint(&config_buf,
        \\.{{
        \\    .address = "{s}", .port = {d}, .workers = 2,
        \\    .tls = .{{ .enabled = false }},
        \\    .log_network_payloads = false,
        \\    .snapshot = .{{ .path = "{s}/snapshots" }},
        \\    .aof = .{{ .flush_strategy = .{s}, .path = "{s}/appendonly.aof" }},
        \\    .whitelist = .{{ "{s}" }},
        \\}}
    , .{ consts.HOST, consts.PORT, path, if (mode == .aof) "always" else "no", path, consts.HOST });
    try cwd.writeFile(io, .{ .sub_path = config_path, .data = config });

    std.debug.print("\n[{s} crash recovery] ", .{@tagName(mode)});
    for (0..3) |boot| {
        var child = try runServer(false, config_path, log_path);
        defer if (child.id != null) {
            child.kill(io);
        };
        {
            var socket = try connectUnsecure(Stream);
            defer socket.close();
            if (boot == 0) {
                try expectCommand(&socket, &.{ "SET", "durable", "first" }, "write before crash", "+OK\r\n");
                if (mode == .snapshot) try expectCommand(&socket, &.{"SAVE"}, "save before crash", "+OK\r\n");
            } else {
                try expectCommand(&socket, &.{ "GET", "durable" }, "restore acknowledged write", "$5\r\nfirst\r\n");
                try expectCommand(&socket, &.{ "GET", "incomplete" }, "ignore partial write", "-NOT_FOUND\r\n");
                if (boot == 1) {
                    try expectCommand(&socket, &.{ "SET", "after", "second" }, "write after recovery", "+OK\r\n");
                    if (mode == .snapshot) try expectCommand(&socket, &.{"SAVE"}, "save after recovery", "+OK\r\n");
                } else {
                    try expectCommand(&socket, &.{ "GET", "after" }, "restore write after recovery", "$6\r\nsecond\r\n");
                }
            }
        }
        const pid = child.id orelse return error.ChildAlreadyWaited;
        try std.posix.kill(pid, .KILL);
        const term = try child.wait(io);
        if (term != .signal or term.signal != .KILL) return error.ServerNotKilled;

        if (boot == 0) {
            var file_path_buf: [160]u8 = undefined;
            const file_path = try std.fmt.bufPrint(&file_path_buf, "{s}/{s}", .{ path, if (mode == .aof)
                "appendonly.aof"
            else
                "snapshots/dump_9223372036854775807.zcpf" });
            if (mode == .aof) {
                const file = try cwd.openFile(io, file_path, .{ .mode = .read_write });
                defer file.close(io);
                const size = (try file.stat(io)).size;
                try io.vtable.fileSeekTo(io.userdata, file, size);
                try file.writeStreamingAll(io, "*3\r\n$3\r\nSET\r\n$10\r\nincomplete\r\n$5\r\n");
            } else {
                try cwd.writeFile(io, .{ .sub_path = file_path, .data = "zcpf%1\r\n:12345678\r\n$10\r\nincomplete" });
            }
        }
    }
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
        "-NOT_FOUND\r\n",
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
        "-NOT_FOUND\r\n",
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

    try sendAndExpect(
        socket,
        "*5\r\n$6\r\nMSETNX\r\n$7\r\ncounter\r\n:40\r\n$7\r\nmessage\r\n$5\r\nhello\r\n\x03",
        "MSETNX new keys",
        ":1\r\n",
        false,
    );
    try sendAndExpect(
        socket,
        "*5\r\n$6\r\nMSETNX\r\n$4\r\nkey1\r\n:9\r\n$11\r\nnot-created\r\n$5\r\nvalue\r\n\x03",
        "MSETNX existing key is atomic",
        ":0\r\n",
        false,
    );
    try sendAndExpect(
        socket,
        "*2\r\n$4\r\nINCR\r\n$7\r\ncounter\r\n\x03",
        "INCR counter",
        ":41\r\n",
        false,
    );
    try sendAndExpect(
        socket,
        "*2\r\n$4\r\nDECR\r\n$7\r\ncounter\r\n\x03",
        "DECR counter",
        ":40\r\n",
        false,
    );
    try sendAndExpect(
        socket,
        "*3\r\n$6\r\nAPPEND\r\n$7\r\nmessage\r\n$6\r\n world\r\n\x03",
        "APPEND message",
        ":11\r\n",
        false,
    );
    try sendAndExpect(
        socket,
        "*2\r\n$3\r\nGET\r\n$7\r\nmessage\r\n\x03",
        "GET appended message",
        "$11\r\nhello world\r\n",
        false,
    );
    try sendAndExpect(
        socket,
        "*2\r\n$3\r\nGET\r\n$11\r\nnot-created\r\n\x03",
        "MSETNX did not insert another key",
        "-NOT_FOUND\r\n",
        false,
    );
    try sendAndExpect(
        socket,
        "*2\r\n$6\r\nDELETE\r\n$7\r\ncounter\r\n\x03",
        "DELETE counter",
        "+OK\r\n",
        false,
    );
    try sendAndExpect(
        socket,
        "*2\r\n$6\r\nDELETE\r\n$7\r\nmessage\r\n\x03",
        "DELETE message",
        "+OK\r\n",
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
        "-NOT_FOUND\r\n",
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
        "-NOT_FOUND\r\n",
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
        "-NOT_FOUND\r\n",
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
        "-NOT_FOUND\r\n",
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
        "-NOT_FOUND\r\n",
        false,
    );
}
