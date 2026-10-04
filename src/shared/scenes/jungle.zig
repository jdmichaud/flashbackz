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
const equipment_mod = @import("../equipment.zig");
const inventory_menu = @import("inventory_menu.zig");
const props_mod = @import("../world_props.zig");
const text_renderer = @import("../render/text.zig");
const terrain_mod = @import("../terrain.zig");

pub const HeldInput = struct {
    left: bool = false,
    right: bool = false,
    up: bool = false,
    down: bool = false,
    left_action: bool = false,
    right_action: bool = false,
    inventory: bool = false,
    use_item: bool = false,
    use_held: bool = false,
    use_blocked: bool = false,
    previous_direction: struct { horizontal: ?motion.Facing = null, vertical: ?controls.Vertical = null, conflict: bool = false } = .{},
    pub fn key(self: *HeldInput, key_code: platform.Key, down: bool) void {
        switch (key_code) {
            .left => self.left = down,
            .right => self.right = down,
            .up => self.up = down,
            .down => self.down = down,
            .left_shift => self.left_action = down,
            .right_shift => self.right_action = down,
            .tab => self.inventory = down,
            .enter => {
                self.use_held = down;
                if (!down) self.use_blocked = false;
                self.use_item = down and !self.use_blocked;
            },
            else => {},
        }
    }
    pub fn consumeUse(self: *HeldInput) void {
        self.use_item = false;
        self.use_blocked = self.use_held;
    }
    pub fn intent(self: *HeldInput) !conrad.Intent {
        const horizontal: ?motion.Facing = if (self.left and !self.right) .left else if (self.right and !self.left) .right else null;
        const vertical: ?controls.Vertical = if (self.up and !self.down) .up else if (self.down and !self.up) .down else null;
        // Mixed axes retain the last accepted direction, while the action modifier remains
        // current. This is the original input arbitration, expressed without a DOS bitmask.
        if (!(self.left or self.right) or !(self.up or self.down)) self.previous_direction = .{ .horizontal = horizontal, .vertical = vertical, .conflict = (self.left and self.right) or (self.up and self.down) };
        return .{ .direction = self.previous_direction.horizontal, .vertical = self.previous_direction.vertical, .action = self.left_action or self.right_action, .use_item = self.use_item, .directions_conflict = self.previous_direction.conflict };
    }
};

fn consumeInput(pending: *std.ArrayList(platform.Event), held: *HeldInput, deadline: u64) !void {
    while (pending.items.len != 0 and pending.items[0].time_ns <= deadline) {
        const event = pending.orderedRemove(0);
        switch (event.payload) {
            .focus_lost => held.* = .{},
            .key_down => |key| {
                switch (key.key) {
                    .space, .left_ctrl, .right_ctrl, .p, .f1, .f2, .f3 => return error.UnimplementedJungleControl,
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
    terrain: terrain_mod.State,
    props: props_mod.World,
    pending_movie: ?props_mod.Movie = null,
    movie_intent: ?controls.Intent = null,
    pose: motion.Pose,
    health: i16,
    death_wait: ?u16 = null,
    defeated: bool = false,
    equipment: equipment_mod.Loadout,
    received_items: []equipment_mod.Received,
    received_count: usize = 0,
    input: HeldInput = .{},
    pending: std.ArrayList(platform.Event) = .empty,
    clock: ?clock_mod.Clock = null,
    simulation_steps: u64 = 0,
    score: u32 = 0,
    inventory_cooldown: u8 = 0,
    menu_entries: []inventory_menu.Entry,
    dialog: ?struct { menu: inventory_menu.Menu, keys: inventory_menu.Keys = .{}, clock: clock_mod.Clock } = null,

    pub fn load(allocator: std.mem.Allocator, source: platform.AssetSource) !Scene {
        return loadWithDifficulty(allocator, source, .normal);
    }

    pub fn loadWithDifficulty(allocator: std.mem.Allocator, source: platform.AssetSource, difficulty: @import("../settings.zig").Difficulty) !Scene {
        var pack = try content.loadWithDifficulty(allocator, source, difficulty);
        errdefer pack.deinit();
        var equipment = try equipment_mod.Loadout.init(allocator, pack.initial_items);
        errdefer equipment.deinit();
        var terrain = try terrain_mod.State.init(allocator, pack.terrain.map(), pack.terrain.materials, .{ .history_limit = pack.terrain.history_allowance });
        errdefer terrain.deinit();
        var props = try props_mod.World.init(allocator, pack.world_props.definitions);
        errdefer props.deinit();
        const received_items = try allocator.alloc(equipment_mod.Received, pack.initial_items.len);
        errdefer allocator.free(received_items);
        const menu_entries = try allocator.alloc(inventory_menu.Entry, pack.initial_items.len);
        return .{
            .allocator = allocator,
            .content = pack,
            .environment = .{ .map = terrain.map(), .room = pack.initial_room, .materials = terrain.view() },
            .terrain = terrain,
            .props = props,
            .pose = pack.initial_pose,
            .health = pack.initial_health,
            .equipment = equipment,
            .received_items = received_items,
            .menu_entries = menu_entries,
        };
    }

    pub fn deinit(self: *Scene) void {
        self.equipment.deinit();
        self.terrain.deinit();
        self.props.deinit();
        self.allocator.free(self.received_items);
        self.allocator.free(self.menu_entries);
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
        if (self.defeated) return;
        if (self.clock == null) self.clock = try clock_mod.Clock.init(clock_mod.jungle, now_ns);
        // Preserve remaining debt for the next host call instead of dropping simulation.
        var work: usize = 0;
        while (self.needsCatchup(now_ns) and work < 8) : (work += 1) {
            if (self.dialog) |*dialog| {
                const deadline = dialog.clock.deadline();
                while (self.pending.items.len != 0 and self.pending.items[0].time_ns <= deadline) {
                    const event = self.pending.orderedRemove(0);
                    switch (event.payload) {
                        .key_down => |key| try dialog.keys.key(key.key, true),
                        .key_up => |key| try dialog.keys.key(key.key, false),
                        .focus_lost => dialog.keys = .{},
                        else => unreachable,
                    }
                }
                switch (dialog.menu.poll(dialog.keys.sample())) {
                    .stay => dialog.clock.consume(),
                    .choose => |index| {
                        const handle = self.equipment.inventory.items()[index];
                        if (!self.equipment.inventory.select(handle)) return error.MissingSelectedItem;
                        self.dialog = null;
                        self.input = .{};
                        self.inventory_cooldown = 10;
                        try self.clock.?.resumeAfterPause(deadline);
                    },
                }
                continue;
            }
            const deadline = self.clock.?.deadline();
            if (self.death_wait) |remaining| {
                if (remaining == 1) {
                    self.defeated = true;
                    return;
                }
                self.death_wait = remaining - 1;
            }
            const intent = if (self.movie_intent) |latched| blk: {
                self.movie_intent = null;
                break :blk latched;
            } else blk: {
                try consumeInput(&self.pending, &self.input, deadline);
                break :blk try self.input.intent();
            };
            try self.props.prepare(self.terrain.map(), &self.equipment, .{ .room = self.environment.room, .position = self.pose.position, .width = self.content.player_contact_width });
            self.controller.pickup_available = self.props.pickup_candidate != null;
            const selected = try self.equipment.selected();
            self.controller.use_available = if (selected) |item| item.definition.use_action != null else false;
            const result = try self.controller.advanceIn(self.content.controllerClips(), intent, &self.pose, &self.environment);
            if (result != .advanced) return error.UnimplementedMovementTransition;
            if (self.controller.fatal_landing) self.health = -1;
            if (self.death_wait == null) self.death_wait = self.controller.death_wait_requested;
            self.received_count = try self.equipment.advance(self.health, self.received_items);
            try self.props.advance(self.terrain.map(), &self.equipment, try self.controller.pressesFloorSwitches(self.content.controllerClips()), self.controller.pickup_requested);
            if (self.props.acquired) |handle| {
                const item = try self.equipment.item(handle);
                self.received_items[self.received_count] = .{ .item = handle, .kind = item.definition.kind };
                self.received_count += 1;
            }
            if (self.props.movie) |movie| self.pending_movie = movie;
            if (self.controller.use_requested) {
                self.input.consumeUse();
                const action = (selected orelse return error.MissingSelectedItem).definition.use_action orelse return error.MissingItemAction;
                switch (action) {
                    .story => |cue| self.pending_movie = cue,
                }
            }
            self.simulation_steps += 1;
            self.clock.?.consume();
            if (self.inventory_cooldown != 0) {
                self.inventory_cooldown -= 1;
            } else if (self.input.inventory and self.health > 0 and self.equipment.inventory.items().len != 0) {
                const items = self.equipment.inventory.items();
                for (items, self.menu_entries[0..items.len]) |handle, *entry| {
                    const item = try self.equipment.item(handle);
                    entry.* = .{ .icon = try self.content.frame(item.definition.icon), .label = item.definition.label, .quantity = if (item.definition.show_quantity) @as(u16, @bitCast(item.quantity)) else null };
                }
                self.dialog = .{ .menu = try inventory_menu.Menu.init(items.len), .clock = try clock_mod.Clock.init(clock_mod.inventory, deadline) };
                self.input = .{};
            }
            if (self.pending_movie != null) return;
        }
    }

    pub fn latchMovieInput(self: *Scene) !void {
        try consumeInput(&self.pending, &self.input, self.clock.?.deadline());
        var intent = try self.input.intent();
        intent.use_item = false;
        self.input.consumeUse();
        self.movie_intent = intent;
    }
    pub fn resumeMovie(self: *Scene, paused_for: u64) !void {
        self.clock.?.origin_ns = try std.math.add(u64, self.clock.?.origin_ns, paused_for);
    }

    pub fn nextDeadline(self: *const Scene) ?u64 {
        if (self.dialog) |dialog| return dialog.clock.deadline();
        return if (self.clock) |clock| clock.deadline() else null;
    }

    pub fn needsCatchup(self: *const Scene, now_ns: u64) bool {
        if (self.defeated) return false;
        return if (self.nextDeadline()) |time| now_ns >= time else false;
    }

    pub fn draw(self: *const Scene, indices: []u8, rgba: []u8) !void {
        const room = try self.content.roomArt(self.environment.room);
        if (indices.len != room.image.pixels.len) return error.InvalidFrameLength;
        @memcpy(indices, room.image.pixels);
        try self.drawProps(.behind_player, room, indices);
        const frame = try self.content.frame(self.pose.visual.id);
        try sprite_renderer.draw(indices, room.image.width, room.image.height, frame, @as(i32, self.pose.position.x) + 8, @as(i32, self.pose.position.y) + 2, .{ .palette_bank = 4, .facing = if (self.pose.visual.mirrored) .mirrored else .original, .occlusion = room.foreground });
        try self.drawProps(.in_front_of_player, room, indices);
        if (try self.equipment.selected()) |selected| {
            const icon = try self.content.frame(selected.definition.icon);
            try sprite_renderer.draw(indices, room.image.width, room.image.height, icon, 232, 8, .{ .palette_bank = 10, .foreground = .overwrite });
        }
        if (self.props.pickup_candidate) |handle| {
            const item = try self.equipment.item(handle);
            try sprite_renderer.draw(indices, room.image.width, room.image.height, try self.content.frame(self.content.world_props.hint_icon), 80, 8, .{ .palette_bank = 10, .foreground = .overwrite });
            const label = item.definition.label;
            try text_renderer.draw(indices, 256, 224, &self.content.inventory_art.font, label, @divTrunc(176 - @as(i32, @intCast(label.len)) * 8, 2), 26, .{ .foreground = 0xe6, .shadow = 0xe2, .palette_bank = 14 });
        }
        if (self.dialog) |dialog| try dialog.menu.draw(self.content.inventory_art.artwork(), self.menu_entries[0..dialog.menu.count], self.score, indices, room.image.width, room.image.height);
        try palette.writeRgba(indices, &room.colors, rgba);
    }

    fn drawProps(self: *const Scene, layer: props_mod.Layer, room: *const @import("../content/room_artwork.zig").Artwork, indices: []u8) !void {
        // Each rendering layer retains content order; the current two objects occupy
        // separate layers, with Conrad drawn between them.
        for (self.props.objects, self.props.definitions, 0..) |object, definition, index| {
            if (definition.layer != layer or definition.footprint.room != self.environment.room or !try self.props.visible(index, &self.equipment)) continue;
            const art = try self.content.frame(object.pose.visual.id);
            try sprite_renderer.draw(indices, room.image.width, room.image.height, art, @as(i32, object.pose.position.x) + 8, @as(i32, object.pose.position.y) + 2, .{ .palette_bank = definition.palette_bank, .facing = if (object.pose.visual.mirrored) .mirrored else .original, .occlusion = room.foreground });
        }
    }

    pub fn stateHash(self: *const Scene) u64 {
        var hash = std.hash.Wyhash.init(0);
        hash.update(&std.mem.toBytes(std.mem.nativeToLittle(i16, self.health)));
        hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u16, self.death_wait orelse 0)));
        hash.update(&.{@intFromBool(self.defeated)});
        self.equipment.hashInto(&hash);
        self.terrain.hashInto(&hash);
        self.props.hashInto(&hash);
        hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, self.score)));
        hash.update(&.{ self.inventory_cooldown, @intFromBool(self.input.inventory), @intFromBool(self.input.use_item), @intFromBool(self.input.use_held), @intFromBool(self.input.use_blocked), @intFromBool(self.dialog != null) });
        if (self.dialog) |dialog| {
            for ([_]u64{ dialog.menu.cursor, dialog.menu.last_displayed, dialog.clock.next_tick, dialog.clock.origin_ns - self.clock.?.origin_ns }) |value|
                hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
            hash.update(&.{ @intFromBool(dialog.menu.score_next), @intFromBool(dialog.menu.view == .score) });
            if (dialog.menu.view == .items) hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, dialog.menu.view.items)));
            const keys = dialog.keys;
            for ([_]bool{ keys.directions.right, keys.directions.left, keys.directions.up, keys.directions.down, keys.previous.right, keys.previous.left, keys.previous.up, keys.previous.down, keys.left_shift, keys.right_shift, keys.space, keys.enter, keys.tab }) |value| hash.update(&.{@intFromBool(value)});
        }
        const activity: u32 = @backingInt(std.meta.activeTag(self.controller.activity));
        const phase: u32 = switch (self.controller.activity) {
            .turning => |p| @backingInt(p),
            .walking, .running => |p| switch (p) {
                .starting => 0,
                .stride => |i| @intCast(i + 1),
            },
            .stopping_run => |p| @backingInt(p),
            .changing_pace => |p| @backingInt(p),
            .reversing_run => |p| @backingInt(p),
            .running_jump => |p| @backingInt(p.phase),
            .jumping => |jump| (@as(u32, @backingInt(jump.kind)) << 8) | @backingInt(jump.phase),
            .crouching => |p| @backingInt(p),
            .rolling => |roll| @backingInt(roll.phase),
            .falling => |fall| @backingInt(fall.phase),
            .ledge => |state| @backingInt(state.phase),
            .dead => |phase| @backingInt(phase),
            .recoiling => |state| (@as(u32, @backingInt(std.meta.activeTag(state.phase))) << 8) | switch (state.phase) {
                .settling, .resting => |landing| @as(u32, @backingInt(landing)),
                else => @as(u32, 0),
            },
            else => 0,
        };
        for ([_]u32{ @backingInt(self.environment.room), @as(u16, @bitCast(self.pose.position.x)), @as(u16, @bitCast(self.pose.position.y)), @backingInt(self.pose.facing), @backingInt(self.pose.visual.id), @intFromBool(self.pose.visual.mirrored), activity, phase, @intCast(self.controller.playback.next_step) }) |value|
            hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, value)));
        for ([_]u64{ self.simulation_steps, if (self.clock) |clock| clock.next_tick else 0 }) |value|
            hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
        const held = [_]u8{ @intFromBool(self.input.left), @intFromBool(self.input.right), @intFromBool(self.input.up), @intFromBool(self.input.down), @intFromBool(self.input.left_action), @intFromBool(self.input.right_action), if (self.input.previous_direction.horizontal) |direction| 1 + @as(u8, @backingInt(direction)) else 0, if (self.input.previous_direction.vertical) |direction| 1 + @as(u8, @backingInt(direction)) else 0, @intFromBool(self.input.previous_direction.conflict) };
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

test "using an item consumes Return until a release and new press" {
    var input: HeldInput = .{};
    input.key(.enter, true);
    try std.testing.expect((try input.intent()).use_item);
    input.consumeUse();
    try std.testing.expect(!(try input.intent()).use_item);
    input.key(.enter, true); // A held key's repeat must not replay the recording.
    try std.testing.expect(!(try input.intent()).use_item);
    input.key(.enter, false);
    input.key(.enter, true);
    try std.testing.expect((try input.intent()).use_item);
}

test "overlapping directions retain ambiguous history until one axis is released" {
    var input: HeldInput = .{};
    input.key(.left, true);
    input.key(.right, true);
    var intent = try input.intent();
    try std.testing.expect(intent.directions_conflict);
    try std.testing.expect(intent.direction == null and !intent.neutralDirections());
    input.key(.up, true);
    input.key(.left, false);
    intent = try input.intent();
    try std.testing.expect(intent.directions_conflict and intent.vertical == null);
    input.key(.right, false);
    intent = try input.intent();
    try std.testing.expect(!intent.directions_conflict);
    try std.testing.expectEqual(controls.Vertical.up, intent.vertical.?);
}
