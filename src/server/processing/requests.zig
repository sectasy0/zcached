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

const consts = @import("../network/consts.zig");

pub const Processor = @This();

const Protocol = proto.ProtocolHandlerT(std.io.FixedBufferStream([]u8).Reader);

cmd_handler: commands.Handler,
context: Context,
allocator: std.mem.Allocator,
protocol: Protocol,

pub fn init(allocator: std.mem.Allocator, context: Context) Processor {
    return .{
        .cmd_handler = commands.Handler.init(
            allocator,
            context,
        ),
        .context = context,
        .allocator = allocator,
        .protocol = Protocol.init(allocator) catch return,
    };
}

pub fn deframe(self: *Processor, connection: *Connection) void {
    var start: usize = 0;
    var idx: usize = 0;

    while (true) {
        const request_end = std.mem.indexOfScalarPos(
            u8,
            connection.accumulator.items,
            start,
            consts.EXT_CHAR,
        ) orelse break;

        const request = connection.accumulator.items[start..request_end];

        self.context.resources.logger.logEvent(.Request, request);

        self.process(connection, request);

        start = request_end + 1;
        idx += 1;
    }

    if (start == connection.accumulator.items.len) {
        // all the data has been processed, clear the buffer
        connection.accumulator.clearRetainingCapacity();
    } else if (start > 0) {
        const remaining = connection.accumulator.items[start..];
        connection.accumulator.items = remaining;
    }
}

pub fn process(self: *Processor, connection: *Connection, request: []u8) void {
    var stream = std.io.fixedBufferStream(request);
    const reader = stream.reader();

    const out_writer = connection.out().any();
    defer connection.signalWritable();

    // defer self.protocol.serializer.resetPosition();

    const result: ZType = self.protocol.serialize(reader) catch |err| {
        errors.handle(
            out_writer,
            err,
            .{},
            self.context.resources.logger,
        ) catch {
            self.context.resources.logger.err(
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
            self.context.resources.logger.err(
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
            self.context.resources.logger.err(
                "* failed to send error: {any}",
                .{err},
            );
        };

        const command_str = command_set.items[0].str;
        self.context.resources.logger.err(
            "* failed to process command: {s}",
            .{command_str},
        );
        return;
    }

    defer self.cmd_handler.free(command_set, &cmd_result);

    const response = self.protocol.deserialize(cmd_result.ok) catch |err| {
        errors.handle(
            out_writer,
            err,
            .{},
            self.context.resources.logger,
        ) catch |er| {
            self.context.resources.logger.err(
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
            self.context.resources.logger.err(
                "* failed to send error: {any}",
                .{er},
            );
        };
    };
    // Write the end character to the outgoing data
    out_writer.writeByte(consts.EXT_CHAR) catch |err| {
        errors.handle(
            out_writer,
            err,
            .{},
            self.context.resources.logger,
        ) catch |er| {
            self.context.resources.logger.err(
                "* failed to send error: {any}",
                .{er},
            );
        };
    };

    self.context.resources.logger.logEvent(.Response, response);
}

pub fn deinit(self: *Processor) void {
    self.protocol.deinit();
}
