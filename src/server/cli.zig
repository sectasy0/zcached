const std = @import("std");

pub const Args = struct {
    @"config-path": ?[]const u8 = null,
    @"log-path": ?[]const u8 = null,

    sout: bool = false,

    version: bool = false,
    help: bool = false,

    pub const shorthands = .{
        .c = "config-path",
        .l = "log-path",
        .s = "sout",
        .v = "version",
        .h = "help",
    };
};

pub const ParserResult = struct {
    parser: Parser,
    args: Args,
};
pub const Parser = struct {
    _process_args: [][:0]u8 = undefined,
    _allocator: std.mem.Allocator,

    args: Args,

    pub fn show_help() !void {
        const stdout = std.io.getStdOut().writer();
        const help_text: []const u8 =
            \\Usage: zcached [OPTIONS]
            \\
            \\Description:
            \\  zcached is a lightweight, high-performance, in-memory key-value database.
            \\
            \\Options:
            \\  -c, --config <str>      Path to the configuration file (default: ./zcached).
            \\  -l, --log-path <str>    Path to the log file (default: ./log/zcached.log).
            \\  -v, --version           Display zcached's version and exit.
            \\  -h, --help              Display this help message and exit.
            \\
            \\Examples:
            \\  zcached --config-path /etc/zcached.conf
            \\
        ;
        try stdout.print("{s}\n", .{help_text});
    }

    pub fn show_version() !void {
        const stdout = std.io.getStdOut().writer();
        const version_text: []const u8 =
            \\zcached 0.0.1
            \\
        ;
        try stdout.print("{s}\n", .{version_text});
    }

    pub fn parse(allocator: std.mem.Allocator) !ParserResult {
        var args = Args{};

        var parser = Parser{ ._allocator = allocator, .args = args };
        parser._process_args = try std.process.argsAlloc(allocator);

        if (parser._process_args.len == 1) return .{ .parser = parser, .args = args };

        inline for (std.meta.fields(Args)) |field| {
            const short = try field_shorthand(field.name);

            const field_args = try args_for_field(
                field,
                short,
                parser._process_args,
            );
            if (field_args != null) {
                switch (field.type) {
                    bool => @field(args, field.name) = true,
                    ?[]const u8 => {
                        if (std.mem.eql(u8, field_args.?[1], "")) {
                            try show_help();
                            return error.MissingValue;
                        }

                        @field(args, field.name) = field_args.?[1];
                    },
                    else => return error.InvalidType,
                }
            }
        }
        return .{ .parser = parser, .args = args };
    }

    pub fn deinit(self: *const Parser) void {
        std.process.argsFree(self._allocator, self._process_args);
    }

    fn field_shorthand(field_name: []const u8) ![]const u8 {
        inline for (std.meta.fields(@TypeOf(Args.shorthands))) |shorthand| {
            const value = @field(Args.shorthands, shorthand.name);
            if (std.mem.eql(u8, value, field_name)) return shorthand.name;
        }

        return error.InvalidShorthand;
    }

    fn args_for_field(field: anytype, short: []const u8, args: [][:0]u8) !?[2][]const u8 {
        for (args, 0..) |arg, index| {
            if (index & 1 == 0) continue;
            if (arg.len < 2) return error.InvalidArg;

            if (std.mem.eql(u8, arg[2..], field.name) or std.mem.eql(u8, arg[1..], short)) {
                if (args.len > index + 1) {
                    return .{ field.name, args[index + 1] };
                } else {
                    return .{ field.name, "" };
                }
            }
        }
        return null;
    }
};
