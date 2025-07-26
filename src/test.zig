const std = @import("std");

comptime {
    // protocol
    _ = @import("tests/protocol/handler.zig");
    _ = @import("tests/protocol/serializer.zig");
    _ = @import("tests/protocol/deserializer.zig");
    _ = @import("tests/protocol/types.zig");
    _ = @import("tests/protocol/set.zig");

    // server
    _ = @import("tests/server/connection.zig");
    _ = @import("tests/server/commands.zig");
    _ = @import("tests/server/errors.zig");
    // // _ = @import("src/server/listener.zig");
    _ = @import("tests/server/config.zig");
    _ = @import("tests/server/memory.zig");
    // // _ = @import("server/tracing.zig");
    // // _ = @import("src/server/cli.zig");
    _ = @import("tests/server/logger.zig");
    _ = @import("tests/server/utils.zig");
    _ = @import("tests/server/persistance.zig");
    _ = @import("tests/server/access.zig");

    _ = @import("tests/e2e.zig");
}
