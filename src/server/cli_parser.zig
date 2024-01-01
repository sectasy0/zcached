const std = @import("std");

pub const CLIParser = struct {
    @"config-path": ?[]const u8 = null,
    @"log-path": ?[]const u8 = null,

    version: bool = false,
    help: bool = false,

    // internal struct fields
    _process_args: [][:0]u8 = undefined,
    _allocator: std.mem.Allocator,

    pub const shorthands = .{
        .c = "config-path",
        .l = "log-path",
        .v = "version",
        .h = "help",
    };

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

    pub fn parse(allocator: std.mem.Allocator) !CLIParser {
        var parser = CLIParser{ ._allocator = allocator };
        parser._process_args = try std.process.argsAlloc(allocator);

        if (parser._process_args.len == 1) return parser;

        inline for (std.meta.fields(CLIParser)) |field| {
            // ignore internal struct fields
            if (field.name[0] != '_') {
                const short = try field_shorthand(field.name);

                const field_args = try args_for_field(
                    field,
                    short,
                    parser._process_args,
                );
                if (field_args != null) {
                    switch (field.type) {
                        bool => @field(parser, field.name) = true,
                        ?[]const u8 => {
                            if (std.mem.eql(u8, field_args.?[1], "")) {
                                try show_help();
                                return error.MissingValue;
                            }

                            @field(parser, field.name) = field_args.?[1];
                        },
                        else => return error.InvalidType,
                    }
                }
            }
        }
        return parser;
    }

    pub fn deinit(self: *const CLIParser) void {
        std.process.argsFree(self._allocator, self._process_args);
    }

    fn field_shorthand(field_name: []const u8) ![]const u8 {
        inline for (std.meta.fields(@TypeOf(shorthands))) |shorthand| {
            const value = @field(shorthands, shorthand.name);
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
