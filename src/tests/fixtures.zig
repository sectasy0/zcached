const std = @import("std");

const Logger = @import("../server/logger.zig");
const Config = @import("../server/config.zig");

const TracingAllocator = @import("../server/tracing.zig");

const PersistanceHandler = @import("../server/storage/persistance.zig");
const Memory = @import("../server/storage/memory.zig");

pub const ContextFixture = struct {
    allocator: std.mem.Allocator,
    tracing_allocator: TracingAllocator,
    logger: Logger,
    config: Config,
    persistance: ?PersistanceHandler,
    memory: ?Memory,

    pub fn init() !ContextFixture {
        const allocator: std.mem.Allocator = std.testing.allocator;
        const tracing_allocator: TracingAllocator = TracingAllocator.init(allocator);

        const logger: Logger = try Logger.init(allocator, null, false);
        const config: Config = try Config.load(allocator, null, null);

        return ContextFixture{
            .allocator = allocator,
            .tracing_allocator = tracing_allocator,
            .logger = logger,
            .config = config,
            .persistance = null,
            .memory = null,
        };
    }

    pub fn create_memory(self: *ContextFixture) !void {
        if (self.memory != null) self.memory.?.deinit();
        if (self.persistance == null) try self.create_persistance();

        self.memory = Memory.init(self.tracing_allocator.allocator(), self.config, &self.persistance.?);
    }
    pub fn create_persistance(self: *ContextFixture) !void {
        if (self.persistance != null) self.persistance.?.deinit();

        self.persistance = try PersistanceHandler.init(self.allocator, self.config, self.logger, null);
    }

    pub fn deinit(self: *ContextFixture) void {
        self.config.deinit();
        if (self.persistance != null) self.persistance.?.deinit();
        if (self.memory != null) self.memory.?.deinit();
    }
};
