const std = @import("std");
const cli = @import("../../server/cli.zig");

fn testArgs(allocator: std.mem.Allocator, values: []const []const u8) ![][:0]u8 {
    const args = try allocator.alloc([:0]u8, values.len);
    var initialized: usize = 0;
    errdefer {
        for (args[0..initialized]) |arg| allocator.free(arg);
        allocator.free(args);
    }

    for (values, 0..) |value, index| {
        args[index] = try allocator.dupeZ(u8, value);
        initialized += 1;
    }
    return args;
}

fn freeTestArgs(allocator: std.mem.Allocator, args: []const [:0]u8) void {
    for (args) |arg| allocator.free(arg);
    allocator.free(args);
}

test "CLI parses long option values and boolean short options" {
    const allocator = std.testing.allocator;
    const argv = try testArgs(allocator, &.{
        "zcached",
        "--config-path",
        "./test-config.zon",
        "-s",
        "-d",
    });
    defer freeTestArgs(allocator, argv);

    const args = try cli.Parser.parseArgs(argv);
    try std.testing.expectEqualStrings("./test-config.zon", args.@"config-path".?);
    try std.testing.expect(args.sout);
    try std.testing.expect(args.daemon);
}

test "CLI parses shorthand option values and long boolean options" {
    const allocator = std.testing.allocator;
    const argv = try testArgs(allocator, &.{
        "zcached",
        "-c",
        "./short-config.zon",
        "--version",
    });
    defer freeTestArgs(allocator, argv);

    const args = try cli.Parser.parseArgs(argv);
    try std.testing.expectEqualStrings("./short-config.zon", args.@"config-path".?);
    try std.testing.expect(args.version);
}
