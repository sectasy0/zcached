const std = @import("std");

pub const AnyType = union(enum) {
    str: []u8,
    sstr: []u8, // simple string
    int: i64,
    float: f64,
    map: map,
    bool: bool,
    array: array,
    null: void,
    // ClientError only for compatibility with ProtocolHandler
    // and it will not be stored in MemoryStorage but will be returned
    err: ClientError,

    pub const array = std.ArrayList(AnyType);
    pub const map = std.StringHashMap(AnyType);
};

pub const ClientError = struct {
    message: []const u8,
};
