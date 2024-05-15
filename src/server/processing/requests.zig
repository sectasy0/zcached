const std = @import("std");
const Connection = @import("../network/connection.zig");

const Logger = @import("../logger.zig");
const utils = @import("../utils.zig");

const proto = @import("../../protocol/handler.zig");
const ZType = @import("../../protocol/types.zig").ZType;

const Context = @import("employer.zig").Context;
const commands = @import("commands.zig");
const errors = @import("errors.zig");

pub const Processor = @This();

cmd_handler: commands.Handler,
context: Context,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, context: Context) Processor {
    return .{
        .cmd_handler = commands.Handler.init(
            allocator,
            context.memory,
            context.logger,
        ),
        .context = context,
        .allocator = allocator,
    };
}

pub fn process(self: *Processor, connection: *Connection) void {
    var stream = std.io.fixedBufferStream(connection.buffer);
    var reader = stream.reader();

    const ProtocolHandler = proto.ProtocolHandlerT(@TypeOf(&reader));
    var protocol = ProtocolHandler.init(self.allocator) catch return;
    defer protocol.deinit();

    const result: ZType = protocol.serialize(&reader) catch |err| {
        errors.handle(
            connection.stream,
            err,
            .{},
            self.context.logger,
        ) catch {
            self.context.logger.log(
                .Error,
                "* failed to send error: {any}",
                .{err},
            );
        };

        return;
    };

    if (result != .array) {
        errors.handle(
            connection.stream,
            error.UnknownCommand,
            .{},
            self.context.logger,
        ) catch |err| {
            self.context.logger.log(
                .Error,
                "* failed to send error: {any}",
                .{err},
            );
        };
        return;
    }

    const command_set = &result.array;
    defer command_set.deinit();

    var cmd_result = self.cmd_handler.process(command_set);
    if (cmd_result != .ok) {
        const args = errors.build_args(command_set);

        errors.handle(
            connection.stream,
            cmd_result.err,
            args,
            self.context.logger,
        ) catch |err| {
            self.context.logger.log(
                .Error,
                "* failed to send error: {any}",
                .{err},
            );
        };

        self.context.logger.log(
            .Error,
            "* failed to process command: {s}",
            .{command_set.items[0].str},
        );
        return;
    }

    defer self.cmd_handler.free(command_set, &cmd_result);

    const response = protocol.deserialize(cmd_result.ok) catch |err| {
        errors.handle(
            connection.stream,
            err,
            .{},
            self.context.logger,
        ) catch |er| {
            self.context.logger.log(
                .Error,
                "* failed to send error: {any}",
                .{er},
            );
        };
        return;
    };
    connection.stream.writer().writeAll(response) catch |err| {
        errors.handle(
            connection.stream,
            err,
            .{},
            self.context.logger,
        ) catch |er| {
            self.context.logger.log(
                .Error,
                "* failed to send error: {any}",
                .{er},
            );
        };
    };

    self.context.logger.log_event(.Response, response);
}
