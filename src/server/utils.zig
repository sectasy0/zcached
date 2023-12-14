const std = @import("std");

pub fn to_uppercase(str: []u8) []u8 {
    var result: [1024]u8 = undefined;
    for (str, 0..) |c, index| result[index] = std.ascii.toUpper(c);
    return result[0..str.len];
}

pub fn ptrCast(comptime T: type, ptr: *anyopaque) *T {
    if (@alignOf(T) == 0) @compileError(@typeName(T));
    return @ptrCast(@alignCast(ptr));
}

test "to_uppercase" {
    const str = @constCast("hello world");
    const expected = @constCast("HELLO WORLD");
    const actual = to_uppercase(str);
    try std.testing.expectEqualStrings(expected, actual);
}
