//! Runs one condition or effect. Each vocabulary name is implemented once, in one of the
//! group files below, as a function named like the name in camel case (`no_floor_ahead` is
//! `noFloorAhead`). Conditions return whether they hold; effects return true. Some original
//! conditions also change the world; they do so whether or not a later check fails.
const std = @import("std");
const vocabulary = @import("vocabulary.zig");
const World = @import("world.zig").World;

const groups = .{
    @import("operations/input.zig"),
    @import("operations/terrain.zig"),
    @import("operations/messages.zig"),
    @import("operations/timers.zig"),
    @import("operations/presence.zig"),
    @import("operations/presentation.zig"),
    @import("operations/contact.zig"),
    @import("operations/perception.zig"),
    @import("operations/carriers.zig"),
};

pub const Error = error{InvalidAnimation};

pub fn perform(world: *World, actor: u16, operation: vocabulary.Operation) Error!bool {
    switch (operation) {
        inline else => |argument, tag| {
            const name = comptime camelCase(@tagName(tag));
            inline for (groups) |group| {
                if (@hasDecl(group, name)) return @field(group, name)(world, actor, argument);
            }
            @compileError("no group implements " ++ @tagName(tag));
        },
    }
}

fn camelCase(comptime name: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(10_000);
        var result: []const u8 = "";
        var upper = false;
        for (name) |c| {
            if (c == '_') {
                upper = true;
            } else {
                result = result ++ .{if (upper) std.ascii.toUpper(c) else c};
                upper = false;
            }
        }
        const final = result;
        return final;
    }
}

test "operation names map to camel-case functions" {
    try std.testing.expectEqualStrings("noFloorAhead", comptime camelCase("no_floor_ahead"));
    try std.testing.expectEqualStrings("received", comptime camelCase("received"));
}

const testing = struct {
    const data_set = @import("data_set.zig");
    const grid = @import("grid.zig");
    const animations = @import("animations.zig");
    const world_module = @import("world.zig");

    const states = [_]vocabulary.State{.{ .name = "idle", .animation = 0, .rules = &.{} }};
    const behaviors = [_]vocabulary.Behavior{.{
        .name = "test",
        .links = &.{"friend"},
        .numbers = &.{ "delay", "room_to_appear" },
        .states = &states,
    }};
    fn character(
        placement: u16,
        kind: vocabulary.Kind,
        facing: data_set.Facing,
    ) data_set.Character {
        return .{
            .name = "c",
            .placement = placement,
            .kind = kind,
            .behavior = 0,
            .start = 0,
            .room = 0,
            .x = 112,
            .y = 214,
            .facing = facing,
            .health = 2,
            .width = 1,
            .active = true,
            .minimum_difficulty = .easy,
            .links = .{ @fromBackingInt(0), null, null, null },
            .numbers = .{ 30, 5, 0, 0 },
        };
    }
    const characters = [_]data_set.Character{
        character(0, .player, .right),
        character(1, .enemy, .left),
    };
    const level: data_set.Level = .{
        .behaviors = &behaviors,
        .characters = &characters,
        .message_names = &.{},
    };
    const animation_bytes = [_]u8{ 1, 0, 2, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 };

    fn world() !world_module.World {
        var layout: [grid.Grid.layout_size]u8 = @splat(0);
        @memset(layout[0..256], 0xff);
        // A wall two cells to the right of column 7 in room 0's bottom body row (row 5).
        layout[256 + 5 * 16 + 9] = 1;
        var w = try world_module.World.init(
            std.testing.allocator,
            &level,
            try animations.Animations.init(&animation_bytes),
            try grid.Grid.init(&layout),
            .{},
        );
        w.column = grid.columnOf(112);
        w.band = grid.bandOf(214);
        return w;
    }
};

test "operations read input, terrain, timers, chance and messages" {
    var w = try testing.world();
    defer w.deinit();
    w.controls = .{ .right = true };
    try std.testing.expect(try perform(&w, 0, .input_forward));
    try std.testing.expect(!try perform(&w, 1, .input_forward));
    try std.testing.expect(try perform(&w, 1, .input_back));
    try std.testing.expect(try perform(&w, 0, .{ .wall_ahead = 2 }));
    try std.testing.expect(!try perform(&w, 0, .{ .wall_ahead = 1 }));
    try std.testing.expect(try perform(&w, 0, .{ .no_wall_behind = 2 }));
    try std.testing.expect(try perform(&w, 1, .{ .set_timer_from = @fromBackingInt(0) }));
    try std.testing.expectEqual(@as(i16, 30), w.characters[1].counter);
    try std.testing.expect(!try perform(&w, 1, .{ .timer_reaches = 0 }));
    try std.testing.expectEqual(@as(i16, 29), w.characters[1].counter);
    // From state 0 the first draw is 0x2b41 = 11073 = 3 * 3691.
    try std.testing.expect(try perform(&w, 1, .{ .chance = 3 }));
    try std.testing.expect(!try perform(&w, 1, .{ .chance = 0 }));
    const call: vocabulary.Message = @fromBackingInt(300);
    try std.testing.expect(try perform(
        &w,
        1,
        .{ .send = .{ .to = @fromBackingInt(0), .message = call } },
    ));
    try std.testing.expect(try perform(&w, 0, .{ .received = call }));
    try std.testing.expect(!try perform(&w, 1, .{ .received = call }));
    try std.testing.expect(try perform(&w, 1, .{ .reveal = @fromBackingInt(1) }));
    try std.testing.expectEqual(@as(u8, 5), w.characters[1].room);
    try std.testing.expect(try perform(&w, 1, .defeated) == false);
    try std.testing.expect(try perform(&w, 1, .remove));
    try std.testing.expectEqual(@as(u32, 200), w.score);
}
