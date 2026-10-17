//! The committed naming overlay: our names for behaviors, their states, links and numbers, and
//! level messages. It is keyed by behavior structure and holds no original content.
const std = @import("std");
const zon = @import("zon.zig");

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
    for (overlay.behaviors) |entry| {
        try plain(entry.name);
        for (entry.states) |state| {
            try plain(state.name);
        }
        for (entry.links) |link| {
            try plain(link.name);
        }
        for (entry.numbers) |number| {
            try plain(number.name);
        }
    }
    for (overlay.messages) |entry| {
        try plain(entry.name);
    }
    return overlay;
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

test "overlay names must be plain identifiers" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const result = parse(std.testing.allocator, arena.allocator(),
        \\.{ .behaviors = .{.{ .key = "1", .name = "two words" }} }
    );
    try std.testing.expectError(error.InvalidOverlayName, result);
}
