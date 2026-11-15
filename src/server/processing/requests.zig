// Standard library
const std = @import("std");

// Networking
const Connection = @import("../network/connection.zig");

// Protocol handling
const proto = @import("../../protocol/handler.zig");
const fixed_buffer_stream = @import("../../protocol/fixed_buffer_stream.zig");
const ZType = @import("../../protocol/types.zig").ZType;

// Application logic
const Context = @import("../context.zig");
const commands = @import("commands.zig");
const errors = @import("errors.zig");

const consts = @import("../network/consts.zig");
const Deserializer = @import("../../protocol/deserializer.zig").Deserializer;

pub const Processor = @This();

const Protocol = proto.ProtocolHandlerT(fixed_buffer_stream.FixedBufferStream.Reader);

cmd_handler: commands.Handler,
context: Context,
protocol: Protocol,

pub fn init(allocator: std.mem.Allocator, context: Context) !Processor {
    return .{
        .cmd_handler = commands.Handler.init(
            allocator,
            context,
        ),
        .context = context,
        .protocol = try Protocol.init(allocator),
    };
}

pub fn deframe(self: *Processor, connection: *Connection) void {
    var start: usize = 0;

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
    }

    if (start == connection.accumulator.items.len) {
        // all the data has been processed, clear the buffer
        connection.accumulator.clearRetainingCapacity();
    } else if (start > 0) {
        const remaining = connection.accumulator.items[start..];
        std.mem.copyForwards(u8, connection.accumulator.items, remaining);
        connection.accumulator.shrinkRetainingCapacity(remaining.len);
    }
}

pub fn process(self: *Processor, connection: *Connection, request: []u8) void {
    defer self.protocol.reset();
    self.cmd_handler.allocator = self.protocol.serializer.arena.allocator();
    var stream = fixed_buffer_stream.fixedBufferStream(request);
    const reader = stream.reader();

    const result: ZType = self.protocol.serialize(reader) catch |err| {
        self.sendError(connection, err, .{});
        return;
    };

    if (result != .array) {
        self.sendError(connection, error.UnknownCommand, .{});
        return;
    }

    const command_set = &result.array;
    defer command_set.deinit();

    var cmd_result = self.cmd_handler.process(command_set);
    if (cmd_result != .ok) {
        const args = errors.buildArgs(command_set);

        self.sendError(connection, cmd_result.err, args);

        const command_str = command_set.items[0].str;
        self.context.resources.logger.err(
            "* failed to process command: {s}",
            .{command_str},
        );
        return;
    }

    defer self.cmd_handler.free(command_set, &cmd_result);

    const start = connection.tx_accumulator.items.len;
    Deserializer.write(&connection.tx_accumulator, cmd_result.ok) catch |err| {
        connection.tx_accumulator.shrinkRetainingCapacity(start);
        self.sendError(connection, err, .{});
        return;
    };
    connection.tx_accumulator.append(consts.EXT_CHAR) catch |err| {
        connection.tx_accumulator.shrinkRetainingCapacity(start);
        self.sendError(connection, err, .{});
        return;
    };

    self.context.resources.logger.logEvent(.Response, connection.tx_accumulator.items[start .. connection.tx_accumulator.items.len - 1]);
}

fn sendError(self: *Processor, connection: *Connection, err: anyerror, args: errors.Args) void {
    errors.handle(connection.out(), err, args, self.context.resources.logger) catch |write_error| {
        self.context.resources.logger.err("* failed to send error: {any}", .{write_error});
    };
}

pub fn deinit(self: *Processor) void {
    self.protocol.deinit();
}
