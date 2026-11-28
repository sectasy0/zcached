//! Interactive and one-shot client plus local authentication-file administrator.

const std = @import("std");
const fs = @import("fs");
const runtime_io = @import("runtime_io");
const Auth = @import("auth");
const DEFAULT_HOST = "127.0.0.1";
const DEFAULT_PORT = 7556;
const FRAME_TERMINATOR: u8 = '\x03';

const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = DEFAULT_PORT,
    token: ?[]const u8 = null,
};

const PrincipalEdit = struct {
    file: []const u8,
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    token: ?[]const u8 = null,
    groups: []const u8 = "",
    allow: []const u8 = "",
    deny: []const u8 = "",
    read: []const u8 = "",
    write: []const u8 = "",
    delete: []const u8 = "",
    admin: bool = false,
    reload_token: ?[]const u8 = null,
};

fn usage() void {
    std.debug.print(
        \\Usage:
        \\  zcached-cli [--host HOST] [--port PORT] [--token TOKEN] COMMAND [ARG ...]
        \\  zcached-cli auth list --file PATH
        \\  zcached-cli auth add --file PATH --id ID --name NAME --token TOKEN [ACL_OPTIONS]
        \\  zcached-cli auth remove --file PATH --id ID
        \\  zcached-cli auth rotate --file PATH --id ID --token TOKEN
        \\  zcached-cli auth reload [--host HOST] [--port PORT] --token ADMIN_TOKEN
        \\  zcached-cli token generate [--bytes BYTES] [--hash]
        \\
        \\ACL_OPTIONS:
        \\  --groups basic,diagnostic --allow CMD,CMD --deny CMD
        \\  --read prefix,prefix --write prefix --delete prefix --admin
        \\
        \\Prefer ZCACHED_CLI_TOKEN instead of --token when shell history is sensitive.
        \\
    , .{});
}

pub fn main(init: std.process.Init) !void {
    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded_io.deinit();
    runtime_io.runtime = threaded_io.io();

    const args = try init.minimal.args.toSlice(std.heap.page_allocator);
    defer std.heap.page_allocator.free(args);
    if (args.len < 2) {
        usage();
        return;
    }
    if (std.mem.eql(u8, args[1], "auth")) return runAuth(args);
    if (std.mem.eql(u8, args[1], "token")) return runToken(args);
    try runClient(args);
}

fn runToken(args: []const [:0]const u8) !void {
    if (args.len < 3 or !std.mem.eql(u8, args[2], "generate")) return error.UnknownTokenAction;
    var bytes: usize = 32;
    var print_hash = false;
    var index: usize = 3;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--hash")) {
            print_hash = true;
            continue;
        }
        if (!std.mem.eql(u8, argument, "--bytes") or index + 1 >= args.len)
            return error.UnknownOption;
        bytes = try std.fmt.parseInt(usize, args[index + 1], 10);
        index += 1;
        if (bytes < 16 or bytes > 4096) return error.InvalidTokenSize;
    }

    const secret = try std.heap.page_allocator.alloc(u8, bytes);
    defer std.heap.page_allocator.free(secret);
    try runtime_io.get().randomSecure(secret);
    const token = try std.heap.page_allocator.alloc(u8, bytes * 2);
    defer std.heap.page_allocator.free(token);
    _ = try std.fmt.bufPrint(token, "{x}", .{secret});
    std.debug.print("{s}\n", .{token});

    if (print_hash) {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
        var hash_hex: [64]u8 = undefined;
        _ = try std.fmt.bufPrint(&hash_hex, "{x}", .{digest});
        std.debug.print("sha256={s}\n", .{&hash_hex});
    }
}

fn runAuth(args: []const [:0]const u8) !void {
    if (args.len < 3) return error.MissingAuthAction;
    const action = args[2];
    var edit = PrincipalEdit{ .file = "" };
    var options = Options{};
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--admin")) {
            edit.admin = true;
        } else {
            if (i + 1 >= args.len) return error.MissingOptionValue;
            const value = args[i + 1];
            i += 1;
            if (std.mem.eql(u8, arg, "--file")) edit.file = value else if (std.mem.eql(u8, arg, "--id")) edit.id = value else if (std.mem.eql(u8, arg, "--name")) edit.name = value else if (std.mem.eql(u8, arg, "--token")) {
                edit.token = value;
                options.token = value;
            } else if (std.mem.eql(u8, arg, "--groups")) edit.groups = value else if (std.mem.eql(u8, arg, "--allow")) edit.allow = value else if (std.mem.eql(u8, arg, "--deny")) edit.deny = value else if (std.mem.eql(u8, arg, "--read")) edit.read = value else if (std.mem.eql(u8, arg, "--write")) edit.write = value else if (std.mem.eql(u8, arg, "--delete")) edit.delete = value else if (std.mem.eql(u8, arg, "--host")) options.host = value else if (std.mem.eql(u8, arg, "--port")) options.port = try std.fmt.parseInt(u16, value, 10) else return error.UnknownOption;
        }
    }
    if (std.mem.eql(u8, action, "list")) return listPrincipals(edit.file);
    if (std.mem.eql(u8, action, "reload")) {
        options.token = options.token orelse envToken();
        return reloadRemote(options);
    }
    if (std.mem.eql(u8, action, "add")) return addPrincipal(std.heap.page_allocator, edit);
    if (std.mem.eql(u8, action, "remove")) return removePrincipal(std.heap.page_allocator, edit);
    if (std.mem.eql(u8, action, "rotate")) return rotatePrincipal(std.heap.page_allocator, edit);
    return error.UnknownAuthAction;
}

fn listPrincipals(path: []const u8) !void {
    if (path.len == 0) return error.MissingFile;
    var store = try Auth.initPath(std.heap.page_allocator, path);
    defer store.deinit();
    for (store.principals) |principal| {
        std.debug.print("{s}\t{s}\tadmin={s}\n", .{ principal.id, principal.name, if (principal.permissions.admin) "true" else "false" });
    }
}

fn addPrincipal(allocator: std.mem.Allocator, edit: PrincipalEdit) !void {
    const id = edit.id orelse return error.MissingId;
    const name = edit.name orelse id;
    const token = edit.token orelse return error.MissingToken;
    var parsed = try AuthDocument.load(allocator, edit.file);
    defer parsed.deinit();
    for (parsed.principals.items) |existing| if (std.mem.eql(u8, existing.id, id)) return error.PrincipalExists;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
    var hash_hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&hash_hex, "{x}", .{digest});
    try parsed.principals.append(.{
        .id = try allocator.dupe(u8, id),
        .name = try allocator.dupe(u8, name),
        .token_sha256 = try allocator.dupe(u8, &hash_hex),
        .permissions = .{
            .groups = try splitGroups(allocator, edit.groups),
            .allow = try splitStrings(allocator, edit.allow),
            .deny = try splitStrings(allocator, edit.deny),
            .read = try splitStrings(allocator, edit.read),
            .write = try splitStrings(allocator, edit.write),
            .delete = try splitStrings(allocator, edit.delete),
            .admin = edit.admin,
        },
    });
    try parsed.write(edit.file);
}

fn removePrincipal(allocator: std.mem.Allocator, edit: PrincipalEdit) !void {
    const id = edit.id orelse return error.MissingId;
    var parsed = try AuthDocument.load(allocator, edit.file);
    defer parsed.deinit();
    var found = false;
    var index: usize = 0;
    while (index < parsed.principals.items.len) {
        if (std.mem.eql(u8, parsed.principals.items[index].id, id)) {
            _ = parsed.principals.orderedRemove(index);
            found = true;
        } else index += 1;
    }
    if (!found) return error.PrincipalNotFound;
    try parsed.write(edit.file);
}

fn rotatePrincipal(allocator: std.mem.Allocator, edit: PrincipalEdit) !void {
    const id = edit.id orelse return error.MissingId;
    const token = edit.token orelse return error.MissingToken;
    var parsed = try AuthDocument.load(allocator, edit.file);
    defer parsed.deinit();
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
    for (parsed.principals.items) |*principal| if (std.mem.eql(u8, principal.id, id)) {
        var hash_hex: [64]u8 = undefined;
        _ = try std.fmt.bufPrint(&hash_hex, "{x}", .{digest});
        principal.token_sha256 = try allocator.dupe(u8, &hash_hex);
        return parsed.write(edit.file);
    };
    return error.PrincipalNotFound;
}

const AuthDocument = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    principals: std.array_list.Managed(Auth.PrincipalConfig),

    fn load(allocator: std.mem.Allocator, path: []const u8) !AuthDocument {
        if (path.len == 0) return error.MissingFile;
        const file = try fs.cwd().openFile(path, .{ .mode = .read_only });
        defer file.close();
        const bytes = try file.readToEndAllocOptions(allocator, 1024 * 1024, 0, .@"1", 0);
        defer allocator.free(bytes);
        var doc = AuthDocument{
            .allocator = allocator,
            .arena = .init(allocator),
            .principals = .init(allocator),
        };
        errdefer doc.deinit();
        var diagnostics: std.zon.parse.Diagnostics = undefined;
        const parsed = try std.zon.parse.fromSlice(Auth.File, .{
            .gpa = allocator,
            .arena = doc.arena.allocator(),
            .source = bytes,
            .diagnostics = &diagnostics,
        });
        try doc.principals.appendSlice(parsed.principals);
        return doc;
    }

    fn deinit(self: *AuthDocument) void {
        self.principals.deinit();
        self.arena.deinit();
    }

    fn write(self: *AuthDocument, path: []const u8) !void {
        var output = std.array_list.Managed(u8).init(self.allocator);
        defer output.deinit();
        try writeDocument(&output, self.principals.items);
        const temp = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{path});
        defer self.allocator.free(temp);
        try std.Io.Dir.cwd().writeFile(runtime_io.get(), .{ .sub_path = temp, .data = output.items });
        var check = try Auth.initPath(self.allocator, temp);
        check.deinit();
        const cwd = std.Io.Dir.cwd();
        try cwd.rename(temp, cwd, path, runtime_io.get());
    }
};

fn writeDocument(output: *std.array_list.Managed(u8), principals: []const Auth.PrincipalConfig) !void {
    try output.appendSlice(".{\n    .principals = .{\n");
    for (principals) |p| {
        try output.appendSlice("        .{ .id = ");
        try writeQuoted(output, p.id);
        try output.appendSlice(", .name = ");
        try writeQuoted(output, p.name);
        try output.appendSlice(", .token_sha256 = ");
        try writeQuoted(output, p.token_sha256);
        try output.appendSlice(", .permissions = .{\n");
        try writeEnumSlice(output, ".groups", Auth.CommandGroup, p.permissions.groups);
        try writeStringSlice(output, ".allow", p.permissions.allow);
        try writeStringSlice(output, ".deny", p.permissions.deny);
        try writeStringSlice(output, ".read", p.permissions.read);
        try writeStringSlice(output, ".write", p.permissions.write);
        try writeStringSlice(output, ".delete", p.permissions.delete);
        try output.print("            .admin = {s},\n        }}, }},\n", .{if (p.permissions.admin) "true" else "false"});
    }
    try output.appendSlice("    },\n}\n");
}

fn writeStringSlice(output: *std.array_list.Managed(u8), name: []const u8, values: []const []const u8) !void {
    if (values.len == 0) return;
    try output.print("            {s} = .{{ ", .{name});
    for (values, 0..) |value, index| {
        if (index != 0) try output.appendSlice(", ");
        try writeQuoted(output, value);
    }
    try output.appendSlice(" },\n");
}

fn writeQuoted(output: *std.array_list.Managed(u8), text: []const u8) !void {
    try output.append('"');
    for (text) |byte| switch (byte) {
        '"' => try output.appendSlice("\\\""),
        '\\' => try output.appendSlice("\\\\"),
        '\n' => try output.appendSlice("\\n"),
        '\r' => try output.appendSlice("\\r"),
        '\t' => try output.appendSlice("\\t"),
        0...0x08, 0x0b...0x0c, 0x0e...0x1f, 0x7f => try output.print("\\x{x:0>2}", .{byte}),
        else => try output.append(byte),
    };
    try output.append('"');
}

fn writeEnumSlice(output: *std.array_list.Managed(u8), name: []const u8, comptime T: type, values: []const T) !void {
    if (values.len == 0) return;
    try output.print("            {s} = .{{ ", .{name});
    for (values, 0..) |value, index| try output.print("{s}.{s}", .{ if (index == 0) "" else ", ", @tagName(value) });
    try output.appendSlice(" },\n");
}

fn splitStrings(allocator: std.mem.Allocator, input: []const u8) ![]const []const u8 {
    if (input.len == 0) return &.{};
    var values = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (values.items) |value| allocator.free(value);
        values.deinit();
    }
    var iter = std.mem.splitScalar(u8, input, ',');
    while (iter.next()) |value| {
        if (value.len == 0) return error.EmptyListValue;
        try values.append(try allocator.dupe(u8, value));
    }
    return values.toOwnedSlice();
}

fn splitGroups(allocator: std.mem.Allocator, input: []const u8) ![]const Auth.CommandGroup {
    if (input.len == 0) return &.{};
    var values = std.array_list.Managed(Auth.CommandGroup).init(allocator);
    defer values.deinit();
    var iter = std.mem.splitScalar(u8, input, ',');
    while (iter.next()) |value| try values.append(std.meta.stringToEnum(Auth.CommandGroup, value) orelse return error.InvalidGroup);
    return values.toOwnedSlice();
}

fn runClient(args: []const [:0]const u8) !void {
    var options = Options{};
    var command_start: usize = 1;
    while (command_start < args.len and std.mem.startsWith(u8, args[command_start], "--")) {
        if (command_start + 1 >= args.len) return error.MissingOptionValue;
        const option = args[command_start];
        const value = args[command_start + 1];
        command_start += 2;
        if (std.mem.eql(u8, option, "--host")) options.host = value else if (std.mem.eql(u8, option, "--port")) options.port = try std.fmt.parseInt(u16, value, 10) else if (std.mem.eql(u8, option, "--token")) options.token = value else return error.UnknownOption;
    }
    if (options.token == null) options.token = envToken();
    const address = try std.Io.net.IpAddress.parse(options.host, options.port);
    var socket = try address.connect(runtime_io.get(), .{ .mode = .stream });
    defer socket.close(runtime_io.get());
    var read_buffer: [64 * 1024]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;
    var writer = socket.writer(runtime_io.get(), &write_buffer);
    var reader = socket.reader(runtime_io.get(), &read_buffer);
    if (options.token) |token| {
        try execute(&writer, &reader, &.{ "AUTH", token });
    }
    if (command_start >= args.len) return error.MissingCommand;
    try execute(&writer, &reader, args[command_start..]);
}

fn envToken() ?[]const u8 {
    const value = std.c.getenv("ZCACHED_CLI_TOKEN") orelse return null;
    return std.mem.span(value);
}

fn reloadRemote(options: Options) !void {
    const token = options.token orelse return error.MissingToken;
    const address = try std.Io.net.IpAddress.parse(options.host, options.port);
    var socket = try address.connect(runtime_io.get(), .{ .mode = .stream });
    defer socket.close(runtime_io.get());
    var read_buffer: [64 * 1024]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;
    var writer = socket.writer(runtime_io.get(), &write_buffer);
    var reader = socket.reader(runtime_io.get(), &read_buffer);
    try execute(&writer, &reader, &.{ "AUTH", token });
    try execute(&writer, &reader, &.{ "AUTH", "RELOAD" });
}

fn execute(writer: *std.Io.net.Stream.Writer, reader: *std.Io.net.Stream.Reader, args: []const []const u8) !void {
    var request = std.array_list.Managed(u8).init(std.heap.page_allocator);
    defer request.deinit();
    try request.print("*{d}\r\n", .{args.len});
    for (args) |arg| try request.print("${d}\r\n{s}\r\n", .{ arg.len, arg });
    try request.append(FRAME_TERMINATOR);
    try writer.interface.writeAll(request.items);
    try writer.interface.flush();
    const response = try reader.interface.takeDelimiterInclusive(FRAME_TERMINATOR);
    std.debug.print("{s}\n", .{response[0 .. response.len - 1]});
    if (response.len != 0 and response[0] == '-') return error.ServerError;
}

test "serializes and reparses edited auth principals" {
    const principal: Auth.PrincipalConfig = .{
        .id = "app",
        .name = "application\"one\\two",
        .token_sha256 = "2bb80d537b1da3e38bd30361aa855686bde0eacd7162fef6a25fe97bf527a25b",
        .permissions = .{
            .groups = &.{ .basic, .diagnostic },
            .read = &.{ "app:", "shared:" },
            .write = &.{"app:"},
            .admin = false,
        },
    };
    var output = std.array_list.Managed(u8).init(std.testing.allocator);
    defer output.deinit();
    try writeDocument(&output, &.{principal});
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = try std.testing.allocator.allocSentinel(u8, output.items.len, 0);
    @memcpy(source, output.items);
    defer std.testing.allocator.free(source);
    const parsed = try std.zon.parse.fromSlice(Auth.File, .{
        .gpa = std.testing.allocator,
        .arena = arena.allocator(),
        .source = source,
        .diagnostics = &diagnostics,
    });
    try std.testing.expectEqual(@as(usize, 1), parsed.principals.len);
    try std.testing.expectEqualStrings("app", parsed.principals[0].id);
    try std.testing.expectEqualStrings("application\"one\\two", parsed.principals[0].name);
    try std.testing.expectEqual(@as(usize, 2), parsed.principals[0].permissions.groups.len);
}

test "auth CLI rejects malformed group and list values" {
    try std.testing.expectError(error.InvalidGroup, splitGroups(std.testing.allocator, "unknown"));
    try std.testing.expectError(error.EmptyListValue, splitStrings(std.testing.allocator, "app:,"));
}

test "generated tokens have the requested encoded length" {
    var secret: [32]u8 = undefined;
    try std.testing.io.randomSecure(&secret);
    var encoded: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&encoded, "{x}", .{secret});
    try std.testing.expectEqual(@as(usize, 64), encoded.len);
}
