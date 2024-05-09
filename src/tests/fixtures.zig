const std = @import("std");

const Logger = @import("../server/logger.zig");
const Config = @import("../server/config.zig");

const TracingAllocator = @import("../server/tracing.zig");
const PersistanceHandler = @import("../server/persistance.zig").PersistanceHandler;
const MemoryStorage = @import("../server/storage.zig");

pub const ContextFixture = struct {
    allocator: std.mem.Allocator,
    tracing_allocator: TracingAllocator,
    logger: Logger,
    config: Config,
    persistance: PersistanceHandler,
    memory_storage: ?MemoryStorage,

    pub fn init() !ContextFixture {
        const allocator: std.mem.Allocator = std.testing.allocator;
        const tracing_allocator: TracingAllocator = TracingAllocator.init(allocator);

        const logger: Logger = try Logger.init(allocator, null, false);
        const config: Config = try Config.load(allocator, null, null);
        const persistance: PersistanceHandler = try PersistanceHandler.init(allocator, config, logger, null);

        return ContextFixture{
            .allocator = allocator,
            .tracing_allocator = tracing_allocator,
            .logger = logger,
            .config = config,
            .persistance = persistance,
            .memory_storage = null,
        };
    }

    pub fn create_memory_storage(self: *ContextFixture) void {
        if (self.memory_storage != null) self.memory_storage.?.deinit();

        self.memory_storage = MemoryStorage.init(self.tracing_allocator.allocator(), self.config, &self.persistance);
    }

    pub fn deinit(self: *ContextFixture) void {
        self.config.deinit();
        self.persistance.deinit();
        if (self.memory_storage != null) self.memory_storage.?.deinit();
    }
};
