//! Interactive development scene using shared content, locomotion and rendering. Its
//! application clock and event queue are independent of presentation and native hosts.
const std = @import("std");
const platform = @import("../platform.zig");
const content = @import("../content/jungle.zig");
const conrad = @import("../actors/conrad.zig");
const environment_mod = @import("../actors/conrad_environment.zig");
const motion = @import("../motion.zig");
const clock_mod = @import("../step_clock.zig");
const sprite_renderer = @import("../render/sprite.zig");
const palette = @import("../content/palette.zig");
const controls = @import("../actors/controls.zig");

pub const HeldInput = struct {
    left: bool = false,
    right: bool = false,
    up: bool = false,
    down: bool = false,
    left_action: bool = false,
    right_action: bool = false,
    previous_direction: struct { horizontal: ?motion.Facing = null, vertical: ?controls.Vertical = null } = .{},
    pub fn key(self: *HeldInput, key_code: platform.Key, down: bool) void {
        switch (key_code) {
            .left => self.left = down,
            .right => self.right = down,
            .up => self.up = down,
            .down => self.down = down,
            .left_shift => self.left_action = down,
            .right_shift => self.right_action = down,
            else => {},
        }
    }
    pub fn intent(self: *HeldInput) !conrad.Intent {
        if ((self.left and self.right) or (self.up and self.down)) return error.UnverifiedOpposingDirections;
        const horizontal: ?motion.Facing = if (self.left) .left else if (self.right) .right else null;
        const vertical: ?controls.Vertical = if (self.up) .up else if (self.down) .down else null;
        // Mixed axes retain the last accepted direction, while the action modifier remains
        // current. This is the original input arbitration, expressed without a DOS bitmask.
        if (horizontal == null or vertical == null) self.previous_direction = .{ .horizontal = horizontal, .vertical = vertical };
        return .{ .direction = self.previous_direction.horizontal, .vertical = self.previous_direction.vertical, .action = self.left_action or self.right_action };
    }
};

fn consumeInput(pending: *std.ArrayList(platform.Event), held: *HeldInput, deadline: u64) !void {
    while (pending.items.len != 0 and pending.items[0].time_ns <= deadline) {
        const event = pending.orderedRemove(0);
        switch (event.payload) {
            .focus_lost => held.* = .{},
            .key_down => |key| {
                switch (key.key) {
                    .space, .tab, .left_ctrl, .right_ctrl, .enter, .p, .f1, .f2, .f3 => return error.UnimplementedJungleControl,
                    else => {},
                }
                held.*.key(key.key, true);
            },
            .key_up => |key| held.*.key(key.key, false),
            else => unreachable,
        }
    }
}

pub const Scene = struct {
    allocator: std.mem.Allocator,
    content: content.Pack,
    controller: conrad.Controller = .{},
    environment: environment_mod.Environment,
    pose: motion.Pose,
    input: HeldInput = .{},
    pending: std.ArrayList(platform.Event) = .empty,
    clock: ?clock_mod.Clock = null,
    simulation_steps: u64 = 0,

    pub fn load(allocator: std.mem.Allocator, source: platform.AssetSource) !Scene {
        const pack = try content.load(allocator, source);
        return .{ .allocator = allocator, .content = pack, .environment = .{ .map = pack.terrain.map(), .room = pack.initial_room }, .pose = pack.initial_pose };
    }

    pub fn deinit(self: *Scene) void {
        self.pending.deinit(self.allocator);
        self.content.deinit();
        self.* = undefined;
    }

    pub fn enqueue(self: *Scene, event: platform.Event) !void {
        switch (event.payload) {
            .key_down, .key_up, .focus_lost => {
                if (self.pending.items.len == 256) return error.InputQueueFull;
                try self.pending.append(self.allocator, event);
            },
            else => {},
        }
    }

    pub fn update(self: *Scene, now_ns: u64) !void {
        if (self.clock == null) self.clock = try clock_mod.Clock.init(clock_mod.jungle, now_ns);
        // Preserve remaining debt for the next host call instead of dropping simulation.
        var work: usize = 0;
        while (self.clock.?.due(now_ns) and work < 8) : (work += 1) {
            const deadline = self.clock.?.deadline();
            try consumeInput(&self.pending, &self.input, deadline);
            const result = try self.controller.advanceIn(self.content.controllerClips(), try self.input.intent(), &self.pose, &self.environment);
            if (result != .advanced) return error.UnimplementedMovementTransition;
            self.simulation_steps += 1;
            self.clock.?.consume();
        }
    }

    pub fn draw(self: *const Scene, indices: []u8, rgba: []u8) !void {
        const room = try self.content.roomArt(self.environment.room);
        if (indices.len != room.image.pixels.len) return error.InvalidFrameLength;
        @memcpy(indices, room.image.pixels);
        const frame = try self.content.frame(self.pose.visual.id);
        try sprite_renderer.draw(indices, room.image.width, room.image.height, frame, @as(i32, self.pose.position.x) + 8, @as(i32, self.pose.position.y) + 2, .{ .palette_bank = 4, .facing = if (self.pose.visual.mirrored) .mirrored else .original, .occlusion = room.foreground });
        try sprite_renderer.draw(indices, room.image.width, room.image.height, &self.content.icon, 232, 8, .{ .palette_bank = 10, .foreground = .overwrite });
        try palette.writeRgba(indices, &room.colors, rgba);
    }

    pub fn stateHash(self: *const Scene) u64 {
        var hash = std.hash.Wyhash.init(0);
        const activity: u32 = @backingInt(std.meta.activeTag(self.controller.activity));
        const phase: u32 = switch (self.controller.activity) {
            .turning => |p| @backingInt(p),
            .walking, .running => |p| switch (p) {
                .starting => 0,
                .stride => |i| @intCast(i + 1),
            },
            .stopping_run => |p| @backingInt(p),
            .jumping => |jump| (@as(u32, @backingInt(jump.kind)) << 8) | @backingInt(jump.phase),
            .crouching => |p| @backingInt(p),
            .rolling => |roll| @backingInt(roll.phase),
            else => 0,
        };
        for ([_]u32{ @backingInt(self.environment.room), @as(u16, @bitCast(self.pose.position.x)), @as(u16, @bitCast(self.pose.position.y)), @backingInt(self.pose.facing), @backingInt(self.pose.visual.id), @intFromBool(self.pose.visual.mirrored), activity, phase, @intCast(self.controller.playback.next_step) }) |value|
            hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, value)));
        for ([_]u64{ self.simulation_steps, if (self.clock) |clock| clock.next_tick else 0 }) |value|
            hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
        const held = [_]u8{ @intFromBool(self.input.left), @intFromBool(self.input.right), @intFromBool(self.input.up), @intFromBool(self.input.down), @intFromBool(self.input.left_action), @intFromBool(self.input.right_action), if (self.input.previous_direction.horizontal) |direction| 1 + @as(u8, @backingInt(direction)) else 0, if (self.input.previous_direction.vertical) |direction| 1 + @as(u8, @backingInt(direction)) else 0 };
        hash.update(&held);
        for (self.pending.items) |event| {
            const relative_time = event.time_ns -| (if (self.clock) |clock| clock.origin_ns else 0);
            hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, relative_time)));
            const kind: u32 = @backingInt(std.meta.activeTag(event.payload));
            hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, kind)));
            const key: u16 = switch (event.payload) {
                .key_down, .key_up => |press| @backingInt(press.key),
                else => 0,
            };
            hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u16, key)));
        }
        return hash.final();
    }
};

test "held controls retain separate shift keys and release directions" {
    var held: HeldInput = .{};
    held.key(.left, true);
    held.key(.left_shift, true);
    held.key(.right_shift, true);
    held.key(.left_shift, false);
    try std.testing.expectEqual(@as(?motion.Facing, .left), (try held.intent()).direction);
    try std.testing.expect((try held.intent()).action);
    held.key(.left, false);
    try std.testing.expect((try held.intent()).direction == null);
    held.key(.right_shift, false);
    try std.testing.expect(!(try held.intent()).action);
}

test "mixed directional axes retain the last sampled direction but use current action state" {
    var held: HeldInput = .{};
    held.key(.left, true);
    try std.testing.expectEqual(@as(?motion.Facing, .left), (try held.intent()).direction);
    held.key(.up, true);
    held.key(.left_shift, true);
    const mixed = try held.intent();
    try std.testing.expectEqual(@as(?motion.Facing, .left), mixed.direction);
    try std.testing.expect(mixed.vertical == null);
    try std.testing.expect(mixed.action);
    held.key(.left, false);
    const vertical = try held.intent();
    try std.testing.expect(vertical.direction == null);
    try std.testing.expectEqual(@as(?controls.Vertical, .up), vertical.vertical);
}

test "late host polling applies queued controls at simulation deadlines and focus loss releases them" {
    var events: std.ArrayList(platform.Event) = .empty;
    defer events.deinit(std.testing.allocator);
    try events.appendSlice(std.testing.allocator, &.{
        .{ .time_ns = 10, .payload = .{ .key_down = .{ .key = .left } } },
        .{ .time_ns = 20, .payload = .{ .key_down = .{ .key = .left_shift } } },
        .{ .time_ns = 30, .payload = .focus_lost },
    });
    var held: HeldInput = .{};
    try consumeInput(&events, &held, 15);
    try std.testing.expect(held.left);
    try std.testing.expect(!held.left_action);
    try std.testing.expectEqual(@as(usize, 2), events.items.len);
    try consumeInput(&events, &held, 25);
    try std.testing.expect(held.left_action);
    try consumeInput(&events, &held, 30);
    try std.testing.expectEqualDeep(HeldInput{}, held);
    try std.testing.expectEqual(@as(usize, 0), events.items.len);
}
