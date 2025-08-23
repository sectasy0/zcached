const std = @import("std");

comptime {
    // protocol
    _ = @import("tests/protocol/handler.zig");
    _ = @import("tests/protocol/serializer.zig");
    _ = @import("tests/protocol/deserializer.zig");
    _ = @import("tests/protocol/types.zig");
    _ = @import("tests/protocol/set.zig");

    // // server
    _ = @import("tests/server/config.zig");
    _ = @import("tests/server/logger.zig");
    _ = @import("server/tracing.zig");
    // _ = @import("src/server/cli.zig");
    _ = @import("tests/server/utils.zig");

    // // server - network
    _ = @import("tests/server/connection.zig");
    // // _ = @import("src/server/listener.zig");

    // // server - processing
    _ = @import("tests/server/commands.zig");
    _ = @import("tests/server/errors.zig");
    // // _ = @import("tests/server/agent.zig");

    // // // server - middleware
    _ = @import("tests/server/access.zig");

    // // server - storage
    // // _ = @import("tests/server/aof.zig");
    _ = @import("tests/server/memory.zig");
    _ = @import("tests/server/persistance.zig");
}
