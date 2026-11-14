const std = @import("std");
const AOF = @import("../../server/storage/aof.zig");
const Context = @import("../../server/processing/employer.zig").Context;
const Commands = @import("../../server/processing/commands.zig");
const ContextFixture = @import("../fixtures.zig").ContextFixture;
const ZType = @import("../../protocol/types.zig").ZType;

fn appendAOFCommand(ptr: *anyopaque, command: []const ZType) anyerror!void {
    const aof: *AOF = @ptrCast(@alignCast(ptr));
    try aof.appendCommand(command);
}

test "AOF stores successful commands and replays them from configured path" {
    var fixture = try ContextFixture.init();
    defer fixture.deinit();
    try fixture.create_memory();

    const path = "tmp/aof-test.aof";
    if (fixture.config.aof.path) |configured_path| {
        fixture.allocator.free(configured_path);
    }
    fixture.config.aof.path = try fixture.allocator.dupe(u8, path);
    fixture.config.aof.flush_strategy = .everysec;
    defer std.fs.cwd().deleteFile(path) catch {};

    var context: Context = fixture.context();
    var aof = try AOF.init(fixture.allocator, context);
    defer aof.deinit();

    context.resources.aof = .{
        .ptr = &aof,
        .append_command = appendAOFCommand,
    };

    var handler = Commands.Handler.init(fixture.allocator, context);
    var command = std.array_list.Managed(ZType).init(fixture.allocator);
    defer command.deinit();
    try command.append(.{ .str = "SET" });
    try command.append(.{ .str = "aof-key" });
    try command.append(.{ .str = "aof-value" });

    const result = handler.process(&command);
    try std.testing.expect(result == .ok);

    fixture.memory.?.flush();
    try aof.flush();
    try aof.replay();

    const value = try fixture.memory.?.get("aof-key");
    try std.testing.expectEqualStrings("aof-value", value.str);
}
