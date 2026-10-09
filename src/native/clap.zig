//! A small command-line parser. A program describes its options and positional arguments once,
//! and the same description drives the parsing and the help text, so the two cannot disagree.
//!
//! Adapted from `clap.zig` of zig-utils (https://github.com/jdmichaud/zig-utils), MIT License,
//! Copyright (c) 2025 JD Michaud: ported to Zig 0.17, with repeated options, positional
//! arguments in counted groups, `--` and `--name=value`, typed numbers, names checked at
//! compile time, and errors returned to the caller instead of ending the process.
//!
//! ```zig
//! const Args = clap.Parser(.{
//!     .name = "copy",
//!     .description = "Copy the files to a directory.",
//!     .options = &.{
//!         .{ .long = "mode", .value = "MODE", .help = "the copies' permissions" },
//!     },
//!     .positionals = &.{
//!         .{ .name = "DIRECTORY", .help = "where to copy" },
//!         .{ .name = "FILE", .help = "the files to copy", .max = 8 },
//!     },
//! });
//! var diagnostic: clap.Diagnostic = .{};
//! const args = Args.parse(arena, arguments_after_the_program_name, &diagnostic) catch |err|
//!     return Args.writeError(stderr, err, diagnostic);
//! if (args.help) return Args.writeHelp(stdout);
//! const mode = args.value("mode"); // ?[]const u8; a misspelled name does not compile
//! const files = args.positional("FILE"); // []const []const u8
//! ```
const std = @import("std");

pub const Option = struct {
    /// The name after `--`.
    long: []const u8,
    /// A one-letter name after `-`, if any.
    short: ?u8 = null,
    /// The value's name in the help; null for a switch, which takes no value.
    value: ?[]const u8 = null,
    /// The help text; further lines after a newline.
    help: []const u8,
    /// The option may be given several times; every value is kept, in order.
    repeats: bool = false,
};

/// A group of positional arguments. The groups take the arguments in order: each takes as many
/// as it may while leaving the groups after it their minimum.
pub const Positional = struct {
    name: []const u8,
    help: []const u8,
    min: usize = 1,
    max: usize = 1,
};

pub const Spec = struct {
    name: []const u8,
    description: []const u8 = "",
    options: []const Option = &.{},
    positionals: []const Positional = &.{},
    /// `-h` and `--help` ask for the help.
    help: bool = true,
};

pub const Error = error{
    UnknownOption,
    MissingValue,
    UnexpectedValue,
    RepeatedOption,
    InvalidValue,
    /// For the program's own checks: `argument` needs `value`, or excludes it.
    NeedsOption,
    ExcludedOption,
    TooManyArguments,
    MissingArgument,
    OutOfMemory,
};

/// The argument at fault, or the name of a missing argument, for the error message; `value` is
/// the value at fault, or the other option of `NeedsOption` and `ExcludedOption`.
pub const Diagnostic = struct {
    argument: []const u8 = "",
    value: []const u8 = "",
};

/// The process's arguments after the program's name, allocated with `allocator` (an arena
/// suits: they live as long as the values parsed from them).
pub fn processArguments(allocator: std.mem.Allocator, args: std.process.Args) ![]const []const u8 {
    const all = try args.toSlice(allocator);
    const rest = try allocator.alloc([]const u8, all.len -| 1);
    for (rest, all[@min(1, all.len)..]) |*out, arg| out.* = arg;
    return rest;
}

pub fn Parser(comptime spec: Spec) type {
    comptime validate(spec);
    return struct {
        const Self = @This();

        /// `-h` or `--help` was given; nothing else was checked.
        help: bool = false,
        /// Each option's values in command-line order; a switch has an empty value per use.
        option_values: [spec.options.len][]const []const u8 = @splat(&.{}),
        positional_values: [spec.positionals.len][]const []const u8 = @splat(&.{}),
        /// Every option given, in command-line order, for programs where the order across
        /// options matters.
        given: []const Given = &.{},
        /// Every positional argument, in order; the groups are parts of it.
        arguments: []const []const u8 = &.{},

        pub const Given = struct { option: usize, value: []const u8 };

        /// The index of option `long` in the description, for comparing with `Given.option`.
        pub fn index(comptime long: []const u8) usize {
            inline for (spec.options, 0..) |option, i| {
                if (comptime std.mem.eql(u8, option.long, long)) return i;
            }
            @compileError(spec.name ++ " has no option --" ++ long);
        }

        const flags = names: {
            var all: [spec.options.len][]const u8 = undefined;
            for (spec.options, &all) |option, *flag_name| flag_name.* = "--" ++ option.long;
            break :names all;
        };

        /// How option `option` (an index, as in `Given`) is written: `--long`.
        pub fn flagName(option: usize) []const u8 {
            return flags[option];
        }

        fn positionalIndex(comptime name: []const u8) usize {
            inline for (spec.positionals, 0..) |group, i| {
                if (comptime std.mem.eql(u8, group.name, name)) return i;
            }
            @compileError(spec.name ++ " has no argument " ++ name);
        }

        /// Whether switch `long` was given.
        pub fn flag(self: Self, comptime long: []const u8) bool {
            const i = comptime index(long);
            if (spec.options[i].value != null) @compileError("--" ++ long ++ " takes a value");
            return self.option_values[i].len != 0;
        }

        /// The last value of option `long`, if given.
        pub fn value(self: Self, comptime long: []const u8) ?[]const u8 {
            const i = comptime index(long);
            if (spec.options[i].value == null) @compileError("--" ++ long ++ " is a switch");
            const all = self.option_values[i];
            return if (all.len == 0) null else all[all.len - 1];
        }

        /// Every value of option `long`, in order.
        pub fn values(self: Self, comptime long: []const u8) []const []const u8 {
            return self.option_values[comptime index(long)];
        }

        pub fn positional(self: Self, comptime name: []const u8) []const []const u8 {
            return self.positional_values[comptime positionalIndex(name)];
        }

        /// The last value of option `long` as a number from `min` to `max`, if given.
        pub fn number(
            self: Self,
            comptime T: type,
            comptime long: []const u8,
            min: T,
            max: T,
            diagnostic: *Diagnostic,
        ) Error!?T {
            const text = self.value(long) orelse return null;
            const result = switch (@typeInfo(T)) {
                .int => std.fmt.parseInt(T, text, 10) catch null,
                .float => std.fmt.parseFloat(T, text) catch null,
                else => @compileError("number: an integer or float type"),
            };
            if (result) |n| if (n >= min and n <= max) return n;
            diagnostic.* = .{ .argument = "--" ++ long, .value = text };
            return error.InvalidValue;
        }

        /// Parses `args`, the arguments after the program's name. The values point into `args`;
        /// the lists belong to the result (`deinit`).
        pub fn parse(allocator: std.mem.Allocator, args: []const []const u8, diagnostic: *Diagnostic) Error!Self {
            var lists: [spec.options.len]std.ArrayList([]const u8) = @splat(.empty);
            defer for (&lists) |*list| list.deinit(allocator);
            var given: std.ArrayList(Given) = .empty;
            defer given.deinit(allocator);
            var loose: std.ArrayList([]const u8) = .empty;
            defer loose.deinit(allocator);
            var i: usize = 0;
            while (i < args.len) : (i += 1) {
                const arg = args[i];
                if (std.mem.eql(u8, arg, "--")) {
                    try loose.appendSlice(allocator, args[i + 1 ..]);
                    break;
                }
                if (spec.help and (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h"))) {
                    return .{ .help = true };
                }
                // A lone dash, an empty argument and anything else not starting with a dash
                // are positional.
                if (arg.len < 2 or arg[0] != '-') {
                    try loose.append(allocator, arg);
                    continue;
                }
                if (comptime spec.options.len == 0) {
                    diagnostic.* = .{ .argument = arg };
                    return error.UnknownOption;
                } else try takeOption(allocator, args, &i, &lists, &given, diagnostic);
            }
            var result: Self = .{};
            errdefer result.deinit(allocator);
            for (&result.option_values, &lists) |*out, *list| out.* = try list.toOwnedSlice(allocator);
            result.given = try given.toOwnedSlice(allocator);
            result.arguments = try loose.toOwnedSlice(allocator);
            try distribute(&result, diagnostic);
            return result;
        }

        /// The option at `args[i.*]` and its value: the rest of the argument after `=`, or the
        /// next argument, which it then consumes.
        fn takeOption(
            allocator: std.mem.Allocator,
            args: []const []const u8,
            i: *usize,
            lists: *[spec.options.len]std.ArrayList([]const u8),
            given: *std.ArrayList(Given),
            diagnostic: *Diagnostic,
        ) Error!void {
            const arg = args[i.*];
            const long_form = arg[1] == '-';
            const name, const inline_value = if (long_form) split: {
                const rest = arg[2..];
                const equals = std.mem.indexOfScalar(u8, rest, '=') orelse break :split .{ rest, null };
                break :split .{ rest[0..equals], rest[equals + 1 ..] };
            } else .{ arg[1..], null };
            const found = find(name, long_form) orelse {
                diagnostic.* = .{ .argument = arg };
                return error.UnknownOption;
            };
            const option = spec.options[found];
            const option_value: []const u8 = if (option.value == null) switch_value: {
                if (inline_value != null) {
                    diagnostic.* = .{ .argument = arg };
                    return error.UnexpectedValue;
                }
                break :switch_value "";
            } else inline_value orelse next: {
                if (i.* + 1 == args.len) {
                    diagnostic.* = .{ .argument = arg };
                    return error.MissingValue;
                }
                i.* += 1;
                break :next args[i.*];
            };
            if (!option.repeats and lists[found].items.len != 0) {
                diagnostic.* = .{ .argument = arg };
                return error.RepeatedOption;
            }
            try lists[found].append(allocator, option_value);
            try given.append(allocator, .{ .option = found, .value = option_value });
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            for (self.option_values) |list| allocator.free(list);
            allocator.free(self.given);
            allocator.free(self.arguments);
            self.* = undefined;
        }

        fn find(name: []const u8, long_form: bool) ?usize {
            inline for (spec.options, 0..) |option, i| {
                if (long_form) {
                    if (std.mem.eql(u8, name, option.long)) return i;
                } else if (option.short) |short| {
                    if (name.len == 1 and name[0] == short) return i;
                }
            }
            return null;
        }

        fn distribute(result: *Self, diagnostic: *Diagnostic) Error!void {
            const loose = result.arguments;
            var at: usize = 0;
            inline for (spec.positionals, 0..) |group, g| {
                comptime var later_min: usize = 0;
                inline for (spec.positionals[g + 1 ..]) |later| later_min += later.min;
                const available = loose.len - at;
                if (available < group.min) {
                    diagnostic.* = .{ .argument = group.name };
                    return error.MissingArgument;
                }
                const take = @min(group.max, @max(group.min, available -| later_min));
                result.positional_values[g] = loose[at .. at + take];
                at += take;
            }
            if (at != loose.len) {
                diagnostic.* = .{ .argument = loose[at] };
                return error.TooManyArguments;
            }
        }

        pub fn writeUsage(w: *std.Io.Writer) std.Io.Writer.Error!void {
            try w.writeAll("usage: " ++ spec.name);
            if (spec.options.len != 0 or spec.help) try w.writeAll(" [OPTIONS]");
            inline for (spec.positionals) |group| {
                const repeated = if (group.max > 1) "..." else "";
                if (group.min == 0) {
                    try w.writeAll(" [" ++ group.name ++ repeated ++ "]");
                } else try w.writeAll(" " ++ group.name ++ repeated);
            }
            try w.writeByte('\n');
        }

        pub fn writeHelp(w: *std.Io.Writer) std.Io.Writer.Error!void {
            try writeUsage(w);
            if (spec.description.len != 0) try w.writeAll(spec.description ++ "\n");
            if (spec.positionals.len != 0) {
                try w.writeAll("\nArguments:\n");
                inline for (spec.positionals) |group| try writeEntry(w, group.name, group.help);
            }
            if (spec.options.len != 0 or spec.help) {
                try w.writeAll("\nOptions:\n");
                if (spec.help) try writeEntry(w, "-h, --help", "show this help");
                inline for (spec.options) |option| try writeEntry(w, comptime label(option), option.help);
            }
        }

        /// `program: message`, the usage line and a pointer to the help, for `err`.
        pub fn writeError(w: *std.Io.Writer, err: Error, diagnostic: Diagnostic) std.Io.Writer.Error!void {
            try w.writeAll(spec.name ++ ": ");
            const argument = diagnostic.argument;
            switch (err) {
                error.UnknownOption => try w.print("unknown option {s}\n", .{argument}),
                error.MissingValue => try w.print("{s} needs a value\n", .{argument}),
                error.UnexpectedValue => try w.print("{s} takes no value\n", .{argument}),
                error.RepeatedOption => try w.print("{s} may be given only once\n", .{argument}),
                error.InvalidValue => try w.print("invalid value for {s}: {s}\n", .{ argument, diagnostic.value }),
                error.NeedsOption => try w.print("{s} needs {s}\n", .{ argument, diagnostic.value }),
                error.ExcludedOption => try w.print("{s} cannot be used with {s}\n", .{ argument, diagnostic.value }),
                error.TooManyArguments => try w.print("unexpected argument {s}\n", .{argument}),
                error.MissingArgument => try w.print("missing {s}\n", .{argument}),
                error.OutOfMemory => try w.writeAll("out of memory\n"),
            }
            try writeUsage(w);
            if (spec.help) try w.writeAll("Run `" ++ spec.name ++ " --help` for the options.\n");
        }

        const column = blk: {
            var widest: usize = if (spec.help) "-h, --help".len else 0;
            for (spec.positionals) |group| widest = @max(widest, group.name.len);
            for (spec.options) |option| widest = @max(widest, label(option).len);
            break :blk @min(widest, 26) + 4;
        };

        fn writeEntry(w: *std.Io.Writer, name: []const u8, help: []const u8) std.Io.Writer.Error!void {
            try w.writeAll("  ");
            try w.writeAll(name);
            if (name.len + 2 >= column) {
                try w.writeByte('\n');
                try w.splatByteAll(' ', column);
            } else try w.splatByteAll(' ', column - 2 - name.len);
            var lines = std.mem.splitScalar(u8, help, '\n');
            try w.writeAll(lines.first());
            while (lines.next()) |line| {
                try w.writeByte('\n');
                try w.splatByteAll(' ', column);
                try w.writeAll(line);
            }
            try w.writeByte('\n');
        }
    };
}

fn label(comptime option: Option) []const u8 {
    const short = if (option.short) |letter| "-" ++ [_]u8{letter} ++ ", " else "    ";
    const value = if (option.value) |name| " " ++ name else "";
    return short ++ "--" ++ option.long ++ value;
}

fn validate(comptime spec: Spec) void {
    for (spec.options, 0..) |option, i| {
        if (spec.help and (std.mem.eql(u8, option.long, "help") or option.short == 'h')) {
            @compileError(spec.name ++ ": --help and -h belong to the parser");
        }
        for (spec.options[i + 1 ..]) |other| {
            if (std.mem.eql(u8, option.long, other.long)) {
                @compileError(spec.name ++ ": --" ++ option.long ++ " is described twice");
            }
            if (option.short != null and option.short == other.short) {
                @compileError(spec.name ++ ": -" ++ [_]u8{option.short.?} ++ " is described twice");
            }
        }
    }
    for (spec.positionals) |group| {
        if (group.min > group.max) @compileError(spec.name ++ ": " ++ group.name ++ " has min above max");
    }
}

const Example = Parser(.{
    .name = "example",
    .description = "An example.",
    .options = &.{
        .{ .long = "verbose", .short = 'v', .help = "say more" },
        .{ .long = "level", .value = "N", .help = "a level, 1 to 9" },
        .{ .long = "key", .value = "F:KEY", .help = "press KEY at frame F\nrepeat for more keys", .repeats = true },
        .{ .long = "a-very-long-option-name", .value = "VALUE", .help = "long" },
    },
    .positionals = &.{
        .{ .name = "OUTPUT", .help = "where to write" },
        .{ .name = "INPUT", .help = "what to read", .min = 0, .max = 3 },
    },
});

fn parseExample(args: []const []const u8, diagnostic: *Diagnostic) !Example {
    return Example.parse(std.testing.allocator, args, diagnostic);
}

test "options, values and positional groups" {
    var diagnostic: Diagnostic = .{};
    var args = try parseExample(&.{ "out", "-v", "--level=4", "--key", "1:a", "in1", "--key", "2:b", "in2" }, &diagnostic);
    defer args.deinit(std.testing.allocator);
    try std.testing.expect(!args.help);
    try std.testing.expect(args.flag("verbose"));
    try std.testing.expectEqualStrings("4", args.value("level").?);
    try std.testing.expectEqual(@as(?u8, 4), try args.number(u8, "level", 1, 9, &diagnostic));
    try std.testing.expectEqual(@as(usize, 2), args.values("key").len);
    try std.testing.expectEqualStrings("2:b", args.values("key")[1]);
    try std.testing.expectEqualStrings("out", args.positional("OUTPUT")[0]);
    try std.testing.expectEqual(@as(usize, 2), args.positional("INPUT").len);
    try std.testing.expectEqual(@as(?[]const u8, null), args.value("a-very-long-option-name"));
    // The order across options is kept.
    try std.testing.expectEqual(@as(usize, 4), args.given.len);
    try std.testing.expectEqual(Example.index("level"), args.given[1].option);
    try std.testing.expectEqualStrings("--level", Example.flagName(args.given[1].option));
}

test "after --, empty and lone-dash arguments are positional" {
    var diagnostic: Diagnostic = .{};
    var args = try parseExample(&.{ "", "-", "--", "--help" }, &diagnostic);
    defer args.deinit(std.testing.allocator);
    try std.testing.expect(!args.help);
    try std.testing.expectEqualStrings("", args.positional("OUTPUT")[0]);
    try std.testing.expectEqualStrings("-", args.positional("INPUT")[0]);
    try std.testing.expectEqualStrings("--help", args.positional("INPUT")[1]);
}

test "the first group left short is the one reported missing" {
    const Two = Parser(.{
        .name = "two",
        .positionals = &.{
            .{ .name = "OUTPUT", .help = "" },
            .{ .name = "INPUT", .help = "", .max = 8 },
        },
    });
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.MissingArgument, Two.parse(std.testing.allocator, &.{"out"}, &diagnostic));
    try std.testing.expectEqualStrings("INPUT", diagnostic.argument);
    try std.testing.expectError(error.MissingArgument, Two.parse(std.testing.allocator, &.{}, &diagnostic));
    try std.testing.expectEqualStrings("OUTPUT", diagnostic.argument);
    var args = try Two.parse(std.testing.allocator, &.{ "out", "a", "b" }, &diagnostic);
    defer args.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), args.positional("INPUT").len);
}

test "help is asked before anything is checked" {
    var diagnostic: Diagnostic = .{};
    var args = try parseExample(&.{ "--level", "3", "-h" }, &diagnostic);
    defer args.deinit(std.testing.allocator);
    try std.testing.expect(args.help);
    // An option's value may start with a dash.
    var level = try parseExample(&.{ "out", "--level", "-h" }, &diagnostic);
    defer level.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("-h", level.value("level").?);
}

test "every mistake is an error naming the argument at fault" {
    const cases = [_]struct { args: []const []const u8, err: Error, argument: []const u8 }{
        .{ .args = &.{ "out", "--frobnicate" }, .err = error.UnknownOption, .argument = "--frobnicate" },
        .{ .args = &.{ "out", "-x" }, .err = error.UnknownOption, .argument = "-x" },
        .{ .args = &.{ "out", "-vv" }, .err = error.UnknownOption, .argument = "-vv" },
        .{ .args = &.{ "out", "--level" }, .err = error.MissingValue, .argument = "--level" },
        .{ .args = &.{ "out", "--verbose=yes" }, .err = error.UnexpectedValue, .argument = "--verbose=yes" },
        .{ .args = &.{ "out", "--level", "1", "--level", "2" }, .err = error.RepeatedOption, .argument = "--level" },
        .{ .args = &.{}, .err = error.MissingArgument, .argument = "OUTPUT" },
        .{ .args = &.{ "out", "a", "b", "c", "d" }, .err = error.TooManyArguments, .argument = "d" },
    };
    for (cases) |case| {
        var diagnostic: Diagnostic = .{};
        try std.testing.expectError(case.err, parseExample(case.args, &diagnostic));
        try std.testing.expectEqualStrings(case.argument, diagnostic.argument);
    }
    var diagnostic: Diagnostic = .{};
    for ([_][]const u8{ "0", "10", "x" }) |level| {
        var args = try parseExample(&.{ "out", "--level", level }, &diagnostic);
        defer args.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidValue, args.number(u8, "level", 1, 9, &diagnostic));
        try std.testing.expectEqualStrings(level, diagnostic.value);
    }
}

test "the help and the messages come from the description" {
    var buffer: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try Example.writeHelp(&w);
    try std.testing.expectEqualStrings(
        \\usage: example [OPTIONS] OUTPUT [INPUT...]
        \\An example.
        \\
        \\Arguments:
        \\  OUTPUT                      where to write
        \\  INPUT                       what to read
        \\
        \\Options:
        \\  -h, --help                  show this help
        \\  -v, --verbose               say more
        \\      --level N               a level, 1 to 9
        \\      --key F:KEY             press KEY at frame F
        \\                              repeat for more keys
        \\      --a-very-long-option-name VALUE
        \\                              long
        \\
    , w.buffered());
    w = .fixed(&buffer);
    try Example.writeError(&w, error.ExcludedOption, .{ .argument = "--level", .value = "--verbose" });
    try std.testing.expectStringStartsWith(w.buffered(), "example: --level cannot be used with --verbose\n");
    w = .fixed(&buffer);
    try Example.writeError(&w, error.MissingValue, .{ .argument = "--level" });
    try std.testing.expectEqualStrings(
        \\example: --level needs a value
        \\usage: example [OPTIONS] OUTPUT [INPUT...]
        \\Run `example --help` for the options.
        \\
    , w.buffered());
}
