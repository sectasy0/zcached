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

/// Processes complete frames until output reaches its flush threshold.
/// Leaves unprocessed bytes in place and updates `receive_start`.
pub fn deframe(self: *Processor, connection: *Connection) void {
    var start = connection.receive_start;
    const watermark = self.context.config.network.max_pending_response_bytes;
    const max_commands = self.context.config.network.max_pipeline_commands;
    var processed: usize = 0;

    while ((watermark == 0 or connection.tx_accumulator.items.len < watermark) and
        (max_commands == 0 or processed < max_commands))
    {
        const request_end = std.mem.indexOfScalarPos(
            u8,
            connection.accumulator.items,
            start,
            consts.EXT_CHAR,
        ) orelse break;

        const request = connection.accumulator.items[start..request_end];

        self.process(connection, request);

        start = request_end + 1;
        processed += 1;
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
    self.context.resources.metrics.commandCompleted();
    self.cmd_handler.allocator = self.protocol.serializer.arena.allocator();
    var stream = fixed_buffer_stream.fixedBufferStream(request);
    const reader = stream.reader();

    const result: ZType = self.protocol.serialize(reader) catch |err| {
        self.sendError(connection, err);
        return;
    };

    if (result != .array) {
        self.sendError(connection, error.UnknownCommand);
        return;
    }

    const command_set = &result.array;
    defer command_set.deinit();
    const max_response = self.context.config.network.max_response_bytes;
    const is_auth = command_set.items.len > 0 and command_set.items[0] == .str and
        std.ascii.eqlIgnoreCase(command_set.items[0].str, "AUTH");
    if (self.context.config.log_network_payloads and !is_auth) {
        self.context.resources.logger.logEvent(.Request, request);
    }

    if (is_auth) {
        self.authenticate(connection, command_set);
        return;
    }
    if (self.context.config.auth.enabled) {
        const principal_index = connection.auth.principal orelse {
            self.sendError(connection, error.NoAuth);
            return;
        };
        if (!self.context.resources.auth.authorize(principal_index, command_set.items)) {
            self.context.resources.metrics.authorizationDenied();
            self.sendError(connection, error.NoPermission);
            return;
        }
    }

    if (isGetCommand(command_set)) {
        self.processGet(connection, command_set, max_response);
        return;
    }

    var cmd_result = self.cmd_handler.process(command_set);
    if (cmd_result != .ok) {
        self.failCommand(connection, cmd_result.err);
        return;
    }

    defer self.cmd_handler.free(command_set, &cmd_result);

    const encoded_len = Deserializer.encodedLen(cmd_result.ok) catch |err| {
        self.sendError(connection, err);
        return;
    };
    if (max_response != 0 and encoded_len > max_response -| 1) {
        self.sendError(connection, error.ResponseTooLarge);
        return;
    }

    const start = connection.tx_accumulator.items.len;
    Deserializer.write(&connection.tx_accumulator, cmd_result.ok) catch |err| {
        connection.tx_accumulator.shrinkRetainingCapacity(start);
        self.sendError(connection, err);
        return;
    };
    connection.tx_accumulator.append(consts.EXT_CHAR) catch |err| {
        connection.tx_accumulator.shrinkRetainingCapacity(start);
        self.sendError(connection, err);
        return;
    };

    if (self.context.config.log_network_payloads) {
        self.context.resources.logger.logEvent(.Response, connection.tx_accumulator.items[start .. connection.tx_accumulator.items.len - 1]);
    }
}

fn authenticate(
    self: *Processor,
    connection: *Connection,
    command_set: *const std.array_list.Managed(ZType),
) void {
    if (!self.context.config.auth.enabled) {
        self.sendError(connection, error.InvalidCommand);
        return;
    }
    if (command_set.items.len != 2 or command_set.items[1] != .str) {
        self.sendError(connection, error.InvalidCommand);
        return;
    }
    self.context.resources.auth.authenticate(
        &connection.auth,
        command_set.items[1].str,
        self.context.config.auth,
    ) catch |err| {
        self.sendError(connection, err);
        return;
    };
    self.sendSimple(connection, "OK");
}

fn sendSimple(self: *Processor, connection: *Connection, text: []const u8) void {
    const start = connection.tx_accumulator.items.len;
    Deserializer.write(&connection.tx_accumulator, .{ .sstr = text }) catch |err| {
        connection.tx_accumulator.shrinkRetainingCapacity(start);
        self.sendError(connection, err);
        return;
    };
    connection.tx_accumulator.append(consts.EXT_CHAR) catch |err| {
        connection.tx_accumulator.shrinkRetainingCapacity(start);
        self.sendError(connection, err);
    };
}

/// Handles GET through storage's read-locked value callback to serialize directly to output.
/// Rolls back partial output before reporting lookup, serialization, or terminator errors.
fn processGet(
    self: *Processor,
    connection: *Connection,
    command_set: *const std.array_list.Managed(ZType),
    max_response: usize,
) void {
    const output_start = connection.tx_accumulator.items.len;
    if (command_set.items.len < 2) {
        self.failCommand(connection, error.InvalidCommand);
        return;
    }
    if (command_set.items[1] != .str) {
        self.failCommand(connection, error.KeyNotString);
        return;
    }

    var limited_output: LimitedOutput = .{
        .output = &connection.tx_accumulator,
        .max_response = max_response,
    };
    self.context.resources.memory.withValue(
        command_set.items[1].str,
        &limited_output,
        appendSerializedValue,
    ) catch |err| {
        connection.tx_accumulator.shrinkRetainingCapacity(output_start);
        self.failCommand(connection, err);
        return;
    };

    connection.tx_accumulator.append(consts.EXT_CHAR) catch |err| {
        connection.tx_accumulator.shrinkRetainingCapacity(output_start);
        self.sendError(connection, err);
        return;
    };

    if (self.context.config.log_network_payloads) {
        self.context.resources.logger.logEvent(.Response, connection.tx_accumulator.items[output_start .. connection.tx_accumulator.items.len - 1]);
    }
}

/// Sends a command error and logs the error code without request-controlled text.
fn failCommand(
    self: *Processor,
    connection: *Connection,
    err: anyerror,
) void {
    self.sendError(connection, err);
    self.context.resources.logger.warn(
        "event=command_failed error={s}",
        .{@errorName(err)},
    );
}

/// Identifies GET case-insensitively so its value can be serialized without an intermediate copy.
fn isGetCommand(command_set: *const std.array_list.Managed(ZType)) bool {
    return command_set.items.len > 0 and
        command_set.items[0] == .str and
        std.ascii.eqlIgnoreCase(command_set.items[0].str, "GET");
}

/// Serializes a value into the managed connection output buffer.
const LimitedOutput = struct {
    output: *std.array_list.Managed(u8),
    max_response: usize,
};

fn appendSerializedValue(output: *const LimitedOutput, value: ZType) !void {
    const encoded_len = try Deserializer.encodedLen(value);
    if (output.max_response != 0 and encoded_len > output.max_response -| 1)
        return error.ResponseTooLarge;
    try Deserializer.write(output.output, value);
}

/// Writes an error response; failures to write are logged because this path cannot return them.
fn sendError(self: *Processor, connection: *Connection, err: anyerror) void {
    self.context.resources.metrics.commandFailed(err);
    errors.handle(connection.out(), err, self.context.resources.logger) catch |write_error| {
        self.context.resources.logger.err("event=error_response_write_failed error={s}", .{@errorName(write_error)});
    };
}

/// Sends a stable transport/session error without requiring a decoded command.
pub fn sendConnectionError(self: *Processor, connection: *Connection, err: anyerror) void {
    self.sendError(connection, err);
}

/// Releases protocol serializer and deserializer resources owned by this processor.
pub fn deinit(self: *Processor) void {
    self.protocol.deinit();
}
