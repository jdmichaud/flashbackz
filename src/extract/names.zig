//! The committed naming overlay: our names for behaviors, their states, links and numbers, and
//! level messages. It is keyed by behavior structure and holds no original content.
const std = @import("std");
const zon = @import("zon.zig");
const codes = @import("codes.zig");

pub const Overlay = struct {
    behaviors: []const Behavior = &.{},
    messages: []const Message = &.{},

    pub fn behavior(self: Overlay, key: []const u8) ?Behavior {
        for (self.behaviors) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry;
        }
        return null;
    }

    /// A level's own name for a message wins over a name for all levels.
    pub fn message(self: Overlay, level: []const u8, value: i16) ?[]const u8 {
        var everywhere: ?[]const u8 = null;
        for (self.messages) |entry| {
            if (entry.value == value) {
                if (std.mem.eql(u8, entry.level, level)) return entry.name;
                if (std.mem.eql(u8, entry.level, "all")) {
                    everywhere = entry.name;
                }
            }
        }
        return everywhere;
    }
};

pub const Behavior = struct {
    key: []const u8,
    name: []const u8,
    /// State names by ordinal: the state's order of first appearance in the behavior's rules,
    /// shown as a comment in each generated behavior file.
    states: []const State = &.{},
    links: []const Parameter = &.{},
    numbers: []const Parameter = &.{},
};

pub const State = struct {
    ordinal: u16,
    name: []const u8,
};
pub const Parameter = struct {
    parameter: u2,
    name: []const u8,
};
/// `level` is a level name, or `all`.
pub const Message = struct {
    level: []const u8,
    value: i16,
    name: []const u8,
};

/// Parse and validate an overlay. Results live in `arena`.
pub fn parse(gpa: std.mem.Allocator, arena: std.mem.Allocator, source: [:0]const u8) !Overlay {
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const overlay = std.zon.parse.fromSlice(Overlay, .{
        .gpa = gpa,
        .arena = arena,
        .source = source,
        .diagnostics = &diagnostics,
    }) catch |err| {
        if (err == error.ParseZon) {
            diagnostics.log("naming overlay");
        }
        return err;
    };
    // Each name is a plain identifier, and nothing is named twice: a second entry would be
    // ignored without a word, as the lookups take the first.
    for (overlay.behaviors, 0..) |entry, b| {
        try plain(entry.name);
        for (overlay.behaviors[0..b]) |earlier| {
            if (std.mem.eql(u8, earlier.key, entry.key)) return error.DuplicateOverlayEntry;
        }
        for (entry.states, 0..) |state, s| {
            try plain(state.name);
            for (entry.states[0..s]) |earlier| {
                if (earlier.ordinal == state.ordinal or std.mem.eql(u8, earlier.name, state.name)) {
                    return error.DuplicateOverlayEntry;
                }
            }
        }
        try parameters(entry.links);
        try parameters(entry.numbers);
    }
    for (overlay.messages, 0..) |entry, m| {
        try plain(entry.name);
        // The engine gives these values its own names (hits, acknowledged); another name would
        // make it miss them.
        if (codes.engineMessage(entry.value) != null) return error.FixedMessageName;
        for (overlay.messages[0..m]) |earlier| {
            if (earlier.value == entry.value and std.mem.eql(u8, earlier.level, entry.level)) {
                return error.DuplicateOverlayEntry;
            }
        }
    }
    return overlay;
}

fn parameters(list: []const Parameter) !void {
    for (list, 0..) |entry, i| {
        try plain(entry.name);
        for (list[0..i]) |earlier| {
            if (earlier.parameter == entry.parameter or std.mem.eql(u8, earlier.name, entry.name)) {
                return error.DuplicateOverlayEntry;
            }
        }
    }
}

fn plain(name: []const u8) !void {
    if (!zon.isPlainIdentifier(name)) return error.InvalidOverlayName;
}

test "overlay names behaviors by key and messages by level, then for all levels" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const overlay = try parse(std.testing.allocator, arena.allocator(),
        \\.{
        \\    .behaviors = .{.{
        \\        .key = "00ff",
        \\        .name = "guard",
        \\        .states = .{.{ .ordinal = 3, .name = "aim" }},
        \\    }},
        \\    .messages = .{
        \\        .{ .level = "all", .value = 20, .name = "call" },
        \\        .{ .level = "city", .value = 20, .name = "alarm" },
        \\    },
        \\}
    );
    try std.testing.expectEqualStrings("aim", overlay.behavior("00ff").?.states[0].name);
    try std.testing.expectEqualStrings("alarm", overlay.message("city", 20).?);
    try std.testing.expectEqualStrings("call", overlay.message("tower", 20).?);
    try std.testing.expectEqual(@as(?[]const u8, null), overlay.message("tower", 21));
}

test "overlay names nothing twice and leaves the engine's messages alone" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const refused = [_]struct { [:0]const u8, anyerror }{
        .{
            ".{ .behaviors = .{ .{ .key = \"1\", .name = \"a\" }, .{ .key = \"1\", .name = \"b\" } } }",
            error.DuplicateOverlayEntry,
        },
        .{
            ".{ .behaviors = .{.{ .key = \"1\", .name = \"a\", .states = .{ .{ .ordinal = 0, .name = \"x\" }, .{ .ordinal = 0, .name = \"y\" } } }} }",
            error.DuplicateOverlayEntry,
        },
        .{
            ".{ .behaviors = .{.{ .key = \"1\", .name = \"a\", .links = .{ .{ .parameter = 0, .name = \"x\" }, .{ .parameter = 1, .name = \"x\" } } }} }",
            error.DuplicateOverlayEntry,
        },
        .{
            ".{ .messages = .{ .{ .level = \"all\", .value = 20, .name = \"a\" }, .{ .level = \"all\", .value = 20, .name = \"b\" } } }",
            error.DuplicateOverlayEntry,
        },
        .{
            ".{ .messages = .{.{ .level = \"all\", .value = 3, .name = \"punch\" }} }",
            error.FixedMessageName,
        },
        .{
            ".{ .messages = .{.{ .level = \"city\", .value = 12, .name = \"ok\" }} }",
            error.FixedMessageName,
        },
    };
    for (refused) |case| {
        try std.testing.expectError(
            case[1],
            parse(std.testing.allocator, arena.allocator(), case[0]),
        );
    }
}

test "overlay names must be plain identifiers" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const result = parse(std.testing.allocator, arena.allocator(),
        \\.{ .behaviors = .{.{ .key = "1", .name = "two words" }} }
    );
    try std.testing.expectError(error.InvalidOverlayName, result);
}
