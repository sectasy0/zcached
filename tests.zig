comptime {
    _ = @import("src/storage.zig");

    // protocol
    _ = @import("src/protocol/handler.zig");
    _ = @import("src/protocol/serializer.zig");
    _ = @import("src/protocol/deserializer.zig");

    // server
    _ = @import("src/server/cmd_handler.zig");
    _ = @import("src/server/err_handler.zig");
    _ = @import("src/server/listener.zig");
    _ = @import("src/server/config.zig");
}
