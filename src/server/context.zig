//! Bundles server resources and the shared runtime state passed to request handlers.

const std = @import("std");
const Config = @import("config.zig");
const Logger = @import("logger.zig");
const Agent = @import("background/agent.zig");
const Memory = @import("storage/memory.zig");
const ZType = @import("../protocol/types.zig").ZType;

/// Type-erased adapter for appending a command to the append-only persistence log.
pub const AOFWriter = struct {
    /// Opaque state expected by `append_command`; its owner must outlive this adapter.
    ptr: *anyopaque,
    /// Callback that serializes one command; implementation errors are propagated.
    append_command: *const fn (ptr: *anyopaque, command: []const ZType) anyerror!void,

    /// Invokes the configured callback without taking ownership of the command slice.
    pub fn appendCommand(self: AOFWriter, command: []const ZType) anyerror!void {
        try self.append_command(self.ptr, command);
    }
};

/// Non-owning references to the core services used while processing a request.
pub const Resources = struct {
    /// In-memory key-value storage.
    memory: *Memory,
    /// Optional adapter for persisting commands to an append-only file.
    aof: ?AOFWriter = null,
    /// Server logger.
    logger: *Logger,
    /// Background task scheduler.
    agent: *Agent,
};

/// Services and configuration shared with request-processing code.
resources: Resources,
/// Configuration remains owned by the server and must outlive this context.
config: *Config,
/// Atomic server lifecycle flag shared with workers.
running: *std.atomic.Value(bool),
