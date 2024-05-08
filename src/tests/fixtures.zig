const std = @import("std");

const Logger = @import("../server/logger.zig");
const Config = @import("../server/config.zig");

const TracingAllocator = @import("../server/tracing.zig");
const PersistanceHandler = @import("../server/persistance.zig").PersistanceHandler;
const MemoryStorage = @import("../server/storage.zig");

const Fixtures = @This();

allocator: std.mem.Allocator,
tracing_allocator: TracingAllocator,
logger: Logger,
config: Config,
persistance: PersistanceHandler,

pub fn init() !Fixtures {
    const allocator: std.mem.Allocator = std.testing.allocator;
    const tracing_allocator: TracingAllocator = TracingAllocator.init(allocator);

    const logger: Logger = try Logger.init(allocator, null, false);
    const config: Config = try Config.load(allocator, null, null);
    const persistance: PersistanceHandler = try PersistanceHandler.init(allocator, config, logger, null);

    return Fixtures{ .allocator = allocator, .tracing_allocator = tracing_allocator, .logger = logger, .config = config, .persistance = persistance };
}

pub fn create_memory_storage(self: *Fixtures) MemoryStorage {
    return MemoryStorage.init(self.tracing_allocator.allocator(), self.config, &self.persistance);
}

pub fn deinit(self: *Fixtures) void {
    self.config.deinit();
    self.persistance.deinit();
}
