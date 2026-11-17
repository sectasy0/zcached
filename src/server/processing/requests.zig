//! Frames incoming byte streams into requests and coordinates protocol decoding,
//! command execution, response serialization, and error reporting.

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

/// Owns the protocol handler and command dispatcher used for incoming requests.
pub const Processor = @This();

const Protocol = proto.ProtocolHandlerT(fixed_buffer_stream.FixedBufferStream.Reader);

/// Command executor whose allocator is switched to the protocol arena per request.
cmd_handler: commands.Handler,
/// Shared configuration and server resources used for logging, storage, and errors.
context: Context,
/// Serializer/deserializer state reused across requests and reset after processing.
protocol: Protocol,

/// Initializes protocol state and a command handler; allocates resources that require `deinit`.
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

/// Processes every complete framed request in the connection accumulator.
/// Leaves an incomplete suffix in place and updates `receive_start` for the next read.
pub fn deframe(self: *Processor, connection: *Connection) void {
    var start = connection.receive_start;

    while (true) {
        const request_end = std.mem.indexOfScalarPos(
            u8,
            connection.accumulator.items,
            start,
            consts.EXT_CHAR,
        ) orelse break;

        const request = connection.accumulator.items[start..request_end];

        if (self.context.config.log_network_payloads) {
            self.context.resources.logger.logEvent(.Request, request);
        }

        self.process(connection, request);

        start = request_end + 1;
    }

    if (start == connection.accumulator.items.len) {
        // all the data has been processed, clear the buffer
        connection.accumulator.clearRetainingCapacity();
        connection.receive_start = 0;
    } else {
        connection.receive_start = start;
    }
}

/// Decodes and executes one request payload, appending one terminated response or error.
/// Request bytes are borrowed; per-request protocol arena allocations are reset on return.
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

    if (isGetCommand(command_set)) {
        self.processGet(connection, command_set);
        return;
    }

    var cmd_result = self.cmd_handler.process(command_set);
    if (cmd_result != .ok) {
        const args = errors.buildArgs(command_set);

        self.failCommand(connection, command_set, cmd_result.err, args);
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

    if (self.context.config.log_network_payloads) {
        self.context.resources.logger.logEvent(.Response, connection.tx_accumulator.items[start .. connection.tx_accumulator.items.len - 1]);
    }
}

/// Handles GET through storage's read-locked value callback to serialize directly to output.
/// Rolls back partial output before reporting lookup, serialization, or terminator errors.
fn processGet(self: *Processor, connection: *Connection, command_set: *const std.array_list.Managed(ZType)) void {
    const output_start = connection.tx_accumulator.items.len;
    const args = errors.buildArgs(command_set);
    if (command_set.items.len < 2) {
        self.failCommand(connection, command_set, error.InvalidCommand, args);
        return;
    }
    if (command_set.items[1] != .str) {
        self.failCommand(connection, command_set, error.KeyNotString, args);
        return;
    }

    self.context.resources.memory.withValue(
        command_set.items[1].str,
        &connection.tx_accumulator,
        appendSerializedValue,
    ) catch |err| {
        connection.tx_accumulator.shrinkRetainingCapacity(output_start);
        self.failCommand(connection, command_set, err, args);
        return;
    };

    connection.tx_accumulator.append(consts.EXT_CHAR) catch |err| {
        connection.tx_accumulator.shrinkRetainingCapacity(output_start);
        self.sendError(connection, err, .{});
        return;
    };

    if (self.context.config.log_network_payloads) {
        self.context.resources.logger.logEvent(.Response, connection.tx_accumulator.items[output_start .. connection.tx_accumulator.items.len - 1]);
    }
}

/// Sends a command error and logs which decoded command failed.
fn failCommand(
    self: *Processor,
    connection: *Connection,
    command_set: *const std.array_list.Managed(ZType),
    err: anyerror,
    args: errors.Args,
) void {
    self.sendError(connection, err, args);
    self.context.resources.logger.err(
        "* failed to process command: {s}",
        .{command_set.items[0].str},
    );
}

/// Identifies GET case-insensitively so its value can be serialized without an intermediate copy.
fn isGetCommand(command_set: *const std.array_list.Managed(ZType)) bool {
    return command_set.items.len > 0 and
        command_set.items[0] == .str and
        std.ascii.eqlIgnoreCase(command_set.items[0].str, "GET");
}

/// Serializes a value into the managed connection output buffer.
fn appendSerializedValue(output: *std.array_list.Managed(u8), value: ZType) !void {
    try Deserializer.write(output, value);
}

/// Writes an error response; failures to write are logged because this path cannot return them.
fn sendError(self: *Processor, connection: *Connection, err: anyerror, args: errors.Args) void {
    errors.handle(connection.out(), err, args, self.context.resources.logger) catch |write_error| {
        self.context.resources.logger.err("* failed to send error: {any}", .{write_error});
    };
}

/// Releases protocol serializer and deserializer resources owned by this processor.
pub fn deinit(self: *Processor) void {
    self.protocol.deinit();
}
