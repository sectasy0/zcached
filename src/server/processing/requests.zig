// Standard library
const std = @import("std");

// Networking
const Connection = @import("../network/connection.zig");

// Logging and utilities
const Logger = @import("../logger.zig");
const utils = @import("../utils.zig");

// Protocol handling
const proto = @import("../../protocol/handler.zig");
const ZType = @import("../../protocol/types.zig").ZType;

// Application logic
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
            context,
        ),
        .context = context,
        .allocator = allocator,
    };
}

pub fn process(self: *Processor, connection: *Connection) void {
    var stream = std.io.fixedBufferStream(connection.accumulator.items);
    var reader = stream.reader();

    const ProtocolHandler = proto.ProtocolHandlerT(@TypeOf(&reader));
    var protocol = ProtocolHandler.init(self.allocator) catch return;
    defer protocol.deinit();

    const out_writer = connection.out().any();
    connection.signalWritable();

    const result: ZType = protocol.serialize(&reader) catch |err| {
        errors.handle(
            out_writer,
            err,
            .{},
            self.context.resources.logger,
        ) catch {
            self.context.resources.logger.log(
                .Error,
                "* failed to send error: {any}",
                .{err},
            );
        };

        return;
    };

    if (result != .array) {
        errors.handle(
            out_writer,
            error.UnknownCommand,
            .{},
            self.context.resources.logger,
        ) catch |err| {
            self.context.resources.logger.log(
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
        const args = errors.buildArgs(command_set);

        errors.handle(
            out_writer,
            cmd_result.err,
            args,
            self.context.resources.logger,
        ) catch |err| {
            self.context.resources.logger.log(
                .Error,
                "* failed to send error: {any}",
                .{err},
            );
        };

        self.context.resources.logger.log(
            .Error,
            "* failed to process command: {s}",
            .{command_set.items[0].str},
        );
        return;
    }

    defer self.cmd_handler.free(command_set, &cmd_result);

    const response = protocol.deserialize(cmd_result.ok) catch |err| {
        errors.handle(
            out_writer,
            err,
            .{},
            self.context.resources.logger,
        ) catch |er| {
            self.context.resources.logger.log(
                .Error,
                "* failed to send error: {any}",
                .{er},
            );
        };
        return;
    };
    out_writer.writeAll(response) catch |err| {
        errors.handle(
            out_writer,
            err,
            .{},
            self.context.resources.logger,
        ) catch |er| {
            self.context.resources.logger.log(
                .Error,
                "* failed to send error: {any}",
                .{er},
            );
        };
    };

    self.context.resources.logger.log_event(.Response, response);
}
