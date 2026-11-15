const std = @import("std");
const fs = @import("fs");

pub const Args = struct {
    @"config-path": ?[]const u8 = null,
    @"log-path": ?[]const u8 = null,

    sout: bool = false,
    daemon: bool = false,
    pid: ?[]const u8 = null,
    version: bool = false,
    help: bool = false,

    pub const shorthands = .{
        .c = "config-path",
        .l = "log-path",
        .s = "sout",
        .d = "daemon",
        .pid = "pid",
        .v = "version",
        .h = "help",
    };
};

pub const ParserResult = struct {
    parser: Parser,
    args: Args,
};
pub const Parser = struct {
    _process_args: []const [:0]const u8 = undefined,
    _allocator: std.mem.Allocator,

    args: Args,

    pub fn showHelp() !void {
        const stdout = fs.File.stdout();
        const help_text: []const u8 =
            \\Usage: zcached [OPTIONS]
            \\
            \\Description:
            \\  zcached is a lightweight, high-performance, in-memory key-value database.
            \\
            \\Options:
            \\  -c, --config <str>      Path to the configuration file (default: ./zcached).
            \\  -l, --log-path <str>    Path to the log file (default: ./logs/zcached.log).
            \\  -d, --daemon            Run zcached as a background process.
            \\  -pid                    Create pid file at specific location.
            \\  -v, --version           Display zcached's version and exit.
            \\  -h, --help              Display this help message and exit.
            \\
            \\Examples:
            \\  zcached --config-path /etc/zcached.conf
            \\
        ;
        try stdout.writeAll(help_text);
        try stdout.writeAll("\n");
    }

    pub fn showVersion() !void {
        const stdout = fs.File.stdout();
        const version_text: []const u8 =
            \\zcached 0.0.1
            \\
        ;
        try stdout.writeAll(version_text);
    }

    pub fn parse(allocator: std.mem.Allocator, process_args: std.process.Args) !ParserResult {
        var parser = Parser{ ._allocator = allocator, .args = .{} };
        parser._process_args = try process_args.toSlice(allocator);
        errdefer parser.deinit();
        parser.args = try parseArgs(parser._process_args);

        return .{ .parser = parser, .args = parser.args };
    }

    pub fn parseArgs(process_args: []const [:0]const u8) !Args {
        var args = Args{};
        if (process_args.len == 1) return args;

        inline for (std.meta.fields(Args)) |field| {
            const short = try fieldShorthand(field.name);

            const field_args = try argsForField(
                field,
                short,
                process_args,
            );
            if (field_args != null) {
                switch (field.type) {
                    bool => @field(args, field.name) = true,
                    ?[]const u8 => {
                        if (std.mem.eql(u8, field_args.?[1], "")) {
                            try showHelp();
                            return error.MissingValue;
                        }

                        @field(args, field.name) = field_args.?[1];
                    },
                    else => return error.InvalidType,
                }
            }
        }
        return args;
    }

    pub fn deinit(self: *const Parser) void {
        self._allocator.free(self._process_args);
    }

    fn fieldShorthand(field_name: []const u8) ![]const u8 {
        inline for (std.meta.fields(@TypeOf(Args.shorthands))) |shorthand| {
            const value = @field(Args.shorthands, shorthand.name);
            if (std.mem.eql(u8, value, field_name)) return shorthand.name;
        }

        return error.InvalidShorthand;
    }

    fn argsForField(field: anytype, short: []const u8, args: []const [:0]const u8) !?[2][]const u8 {
        for (args, 0..) |arg, index| {
            if (index == 0 or arg.len < 2 or arg[0] != '-') continue;

            const is_long = std.mem.startsWith(u8, arg, "--") and
                std.mem.eql(u8, arg[2..], field.name);
            const is_short = !std.mem.startsWith(u8, arg, "--") and
                std.mem.eql(u8, arg[1..], short);
            if (!is_long and !is_short) continue;

            if (field.type == bool) return .{ field.name, "" };
            if (args.len > index + 1) return .{ field.name, args[index + 1] };
            return .{ field.name, "" };
        }
        return null;
    }
};
