const std = @import("std");
const Config = @import("config.zig");
const Logger = @import("logger.zig");
const Agent = @import("background/agent.zig");
const Memory = @import("storage/memory.zig");
const ZType = @import("../protocol/types.zig").ZType;

pub const AOFWriter = struct {
    ptr: *anyopaque,
    append_command: *const fn (ptr: *anyopaque, command: []const ZType) anyerror!void,

    pub fn appendCommand(self: AOFWriter, command: []const ZType) anyerror!void {
        try self.append_command(self.ptr, command);
    }
};

pub const Resources = struct {
    memory: *Memory,
    aof: ?AOFWriter = null,
    logger: *Logger,
    agent: *Agent,
};

resources: Resources,
config: *Config,
running: *std.atomic.Value(bool),
