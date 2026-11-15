comptime {
    _ = @import("tests/protocol/handler.zig");
    _ = @import("tests/protocol/serializer.zig");
    _ = @import("tests/protocol/deserializer.zig");
    _ = @import("tests/protocol/types.zig");
    _ = @import("tests/protocol/set.zig");

    _ = @import("tests/server/config.zig");
    _ = @import("tests/server/cli.zig");
    _ = @import("tests/server/logger.zig");
    _ = @import("server/tracing.zig");
    _ = @import("tests/server/utils.zig");

    _ = @import("tests/background/fifo.zig");
    _ = @import("tests/background/agent.zig");

    _ = @import("tests/network/connection.zig");
    _ = @import("tests/network/stream_server.zig");
    _ = @import("tests/network/server.zig");

    _ = @import("tests/server/commands.zig");
    _ = @import("tests/server/errors.zig");
    _ = @import("tests/server/requests.zig");
    _ = @import("tests/server/access.zig");

    _ = @import("tests/server/memory.zig");
    _ = @import("tests/server/persistance.zig");
    _ = @import("tests/server/aof.zig");
}
