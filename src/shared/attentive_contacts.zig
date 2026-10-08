//! Conversation hosts who turn toward nearby visitors and retain an introduction/reply topic.
const std = @import("std");
const motion = @import("motion.zig");
const geometry = @import("geometry.zig");
const contacts = @import("contacts.zig");
const Circuit = @import("world_props.zig").CircuitId;
pub const Posture = enum {
    centered,
    watching_behind,
    watching_ahead,
    turning_behind,
    turning_ahead,
    centering_from_behind,
    centering_from_ahead,
};
pub const Topic = enum { introduction, reply };
pub const Definition = struct {
    footprint: contacts.Footprint,
    facing: motion.Facing,
    idle: [2][7]motion.Clip,
    speech: [2]motion.Clip,
    messages: [2]@import("world_messages.zig").Id,
    chances: [2][4]i16,
    attention_distance: i16,
    output: Circuit,
    initially_acquainted: bool,
    hint: motion.VisualId,
    label: []const u8,
    priority: u16,
    palette_bank: u4,
    behind_player: bool,
    initially_active: bool,
    wake_nearby: bool,
    accepts_signals: bool,
};
pub const Instance = struct {
    pose: motion.Pose,
    posture: Posture = .centered,
    acquainted: bool,
    topic: ?Topic = null,
    playback: motion.Playback = .{},
    active: bool,
    sound: ?motion.SoundId = null,
    pub fn clip(self: Instance, definition: Definition) motion.Clip {
        return if (self.topic) |topic| definition.speech[@backingInt(topic)] else definition.idle[@intFromBool(self.acquainted)][@backingInt(self.posture)];
    }
};
pub const World = struct {
    allocator: std.mem.Allocator,
    instances: []Instance,
    pulses: []Circuit,
    pulse_count: usize = 0,
    candidate: ?usize = null,
    notice: ?@import("world_messages.zig").Request = null,
    pub fn init(allocator: std.mem.Allocator, definitions: []const Definition) !World {
        const instances = try allocator.alloc(Instance, definitions.len);
        errdefer allocator.free(instances);
        for (instances, definitions) |*instance, definition| {
            const visual = switch (definition.idle[@intFromBool(definition.initially_acquainted)][0].steps[0]) {
                .frame => |f| f.visual,
                .hold => return error.MissingHostVisual,
            };
            instance.* = .{
                .pose = .{
                    .position = definition.footprint.position,
                    .facing = definition.facing,
                    .visual = .{
                        .id = visual.id,
                        .mirrored = visual.mirrored != (definition.facing == .left),
                    },
                },
                .acquainted = definition.initially_acquainted,
                .active = definition.initially_active,
            };
        }
        return .{
            .allocator = allocator,
            .instances = instances,
            .pulses = try allocator.alloc(Circuit, definitions.len),
        };
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.instances);
        self.allocator.free(self.pulses);
    }
    pub fn prepare(
        self: *World,
        definitions: []const Definition,
        map: geometry.Map,
        player: contacts.Footprint,
    ) !void {
        self.candidate = null;
        self.notice = null;
        self.pulse_count = 0;
        const layout: contacts.Layout = .{};
        for (self.instances, definitions, 0..) |*instance, definition, index| {
            instance.sound = null;
            const near = try @import("activation.zig").around(
                map,
                player.room,
                definition.footprint.room,
                instance.pose.position.y,
            );
            if (definition.wake_nearby and near.wake) instance.active = true;
            if (try layout.overlaps(map, player, definition.footprint)) self.candidate = index;
        }
    }
    fn chance(random: anytype, denominator: i16) bool {
        return denominator != 0 and @rem(@as(i16, @bitCast(random.next())), denominator) == 0;
    }
    fn settled(posture: Posture) Posture {
        return switch (posture) {
            .turning_behind => .watching_behind,
            .turning_ahead => .watching_ahead,
            .centering_from_behind, .centering_from_ahead => .centered,
            else => posture,
        };
    }
    pub fn advance(
        self: *World,
        definitions: []const Definition,
        map: geometry.Map,
        player: contacts.Footprint,
        contact_snapshot: contacts.Footprint,
        talk: bool,
        random: anytype,
    ) !void {
        return self.advanceRange(
            definitions,
            map,
            player,
            contact_snapshot,
            talk,
            random,
            0,
            self.instances.len,
        );
    }
    pub fn advanceOne(
        self: *World,
        index: usize,
        definitions: []const Definition,
        map: geometry.Map,
        player: contacts.Footprint,
        contact_snapshot: contacts.Footprint,
        talk: bool,
        random: anytype,
    ) !void {
        return self.advanceRange(
            definitions,
            map,
            player,
            contact_snapshot,
            talk,
            random,
            index,
            index + 1,
        );
    }
    fn advanceRange(
        self: *World,
        definitions: []const Definition,
        map: geometry.Map,
        player: contacts.Footprint,
        contact_snapshot: contacts.Footprint,
        talk: bool,
        random: anytype,
        range_start: usize,
        range_end: usize,
    ) !void {
        for (range_start..range_end) |index| {
            const instance = &self.instances[index];
            const definition = definitions[index];
            const speaking = talk and
                self.candidate == index and
                instance.topic == null and
                (!instance.acquainted or instance.posture == .centered);
            if (speaking and definition.accepts_signals) instance.active = true;
            if (!instance.active) continue;
            var clip = instance.clip(definition);
            if (speaking) instance.playback.completeDisplacement(clip, &instance.pose);
            if (instance.playback.exhausted(clip)) {
                if (instance.topic) |topic| {
                    self.notice = .{
                        .message = definition.messages[@backingInt(topic)],
                        .icon = definition.hint,
                        .priority = definition.priority,
                    };
                    instance.acquainted = true;
                    instance.topic = null;
                    instance.posture = .centered;
                } else if (speaking) {
                    instance.topic = if (instance.acquainted) .reply else .introduction;
                    if (!instance.acquainted) {
                        self.pulses[self.pulse_count] = definition.output;
                        self.pulse_count += 1;
                    }
                } else {
                    const near = try @import("activation.zig").around(
                        map,
                        player.room,
                        definition.footprint.room,
                        instance.pose.position.y,
                    );
                    if (!near.same) {
                        if (!instance.acquainted) instance.posture = settled(instance.posture);
                        if (!(definition.wake_nearby and near.near)) instance.active = false;
                    } else {
                        const layout: contacts.Layout = .{};
                        const touching = try layout.overlaps(
                            map,
                            contact_snapshot,
                            definition.footprint,
                        );
                        const awareness = try @import("actors/perception.zig").observe(
                            map,
                            .{ .room = definition.footprint.room, .pose = instance.pose },
                            player,
                            &.{},
                        );
                        const front = awareness.player(false, definition.attention_distance);
                        const back = awareness.player(true, definition.attention_distance);
                        const chances = definition.chances[@intFromBool(instance.acquainted)];
                        switch (instance.posture) {
                            .centered => if (!touching) {
                                if (back) instance.posture = .turning_behind else if (front) instance.posture = .turning_ahead else if (chance(
                                    random,
                                    chances[0],
                                )) instance.posture = .turning_ahead else if (chance(
                                    random,
                                    chances[1],
                                )) instance.posture = .turning_behind;
                            },
                            .watching_behind => if (touching or (!back and !chance(
                                random,
                                chances[2],
                            ))) {
                                instance.posture = .centering_from_behind;
                            },
                            .watching_ahead => if (touching or (!front and !chance(
                                random,
                                chances[3],
                            ))) {
                                instance.posture = .centering_from_ahead;
                            },
                            else => instance.posture = settled(instance.posture),
                        }
                    }
                }
                instance.playback = .{};
                clip = instance.clip(definition);
            }
            instance.sound = instance.playback.soundOnEntry(clip);
            _ = instance.playback.advance(clip, &instance.pose);
        }
    }
    pub fn hashInto(self: World, hash: *std.hash.Wyhash) void {
        for (self.instances) |instance| for ([_]u64{
            @backingInt(instance.posture),
            @intFromBool(instance.acquainted),
            if (instance.topic) |topic| @as(u64, @backingInt(topic)) + 1 else 0,
            instance.playback.next_step,
            @intFromBool(instance.active),
            @as(u16, @bitCast(instance.pose.position.x)),
            @as(u16, @bitCast(instance.pose.position.y)),
        }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
    }
};
