//! Background civilians choose gestures and settled postures without gameplay scripting.
const std = @import("std");
const motion = @import("motion.zig");
const geometry = @import("geometry.zig");
const activation = @import("activation.zig");
const random_mod = @import("random.zig");
pub const Posture = enum { resting, leaning, watching };
pub const Part = enum { beginning, waiting, ending };
pub const Activity = union(enum) {
    idle: Posture,
    gesture: struct { index: usize, part: Part = .beginning },
};
pub const Choice = struct { gesture: usize, denominator: i16 };
pub const Gesture = struct {
    beginning: motion.Clip,
    waiting: ?motion.Clip = null,
    ending: ?motion.Clip = null,
    release_denominator: i16 = 1,
    finish: Posture,
    entry_forward: i16 = 0,
    exit_forward: i16 = 0,
};
pub const Profile = struct { idle: [3]motion.Clip, choices: [3][]const Choice, gestures: []const Gesture };
pub const Definition = struct {
    width: u8,
    profile: usize,
    room: geometry.RoomId,
    position: motion.Position,
    facing: motion.Facing,
    initial: Activity,
    palette_bank: u4,
    behind_player: bool,
    initially_active: bool,
    wake_nearby: bool,
};
pub const Actor = struct {
    room: geometry.RoomId,
    pose: motion.Pose,
    activity: Activity,
    playback: motion.Playback = .{},
    active: bool,
    sound: ?motion.SoundId = null,
    pub fn clip(self: Actor, profile: Profile) motion.Clip {
        return switch (self.activity) {
            .idle => |posture| profile.idle[@backingInt(posture)],
            .gesture => |state| switch (state.part) {
                .beginning => profile.gestures[state.index].beginning,
                .waiting => profile.gestures[state.index].waiting.?,
                .ending => profile.gestures[state.index].ending.?,
            },
        };
    }
};
pub const World = struct {
    allocator: std.mem.Allocator,
    actors: []Actor,
    pub fn init(
        allocator: std.mem.Allocator,
        definitions: []const Definition,
        profiles: []const Profile,
    ) !World {
        const actors = try allocator.alloc(Actor, definitions.len);
        errdefer allocator.free(actors);
        for (actors, definitions) |*actor, definition| {
            actor.* = .{
                .room = definition.room,
                .pose = .{
                    .position = definition.position,
                    .facing = definition.facing,
                    .visual = .{ .id = @fromBackingInt(0) },
                },
                .activity = definition.initial,
                .active = definition.initially_active,
            };
            const first = switch (actor.clip(profiles[definition.profile]).steps[0]) {
                .frame => |frame| frame.visual,
                .hold => return error.MissingAmbientPersonVisual,
            };
            actor.pose.visual = .{
                .id = first.id,
                .mirrored = first.mirrored != (actor.pose.facing == .left),
            };
        }
        return .{ .allocator = allocator, .actors = actors };
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.actors);
    }
    fn shift(actor: *Actor, forward: i16) void {
        actor.pose.position.x +%= if (actor.pose.facing == .right) forward else -forward;
    }
    pub fn advance(
        self: *World,
        definitions: []const Definition,
        profiles: []const Profile,
        map: geometry.Map,
        player_room: geometry.RoomId,
        random: *random_mod.Stream,
    ) !void {
        for (self.actors, definitions) |*actor, definition| {
            actor.sound = null;
            const near = try activation.around(map, player_room, actor.room, actor.pose.position.y);
            if (definition.wake_nearby and near.wake) actor.active = true;
            if (!actor.active) continue;
            const profile = profiles[definition.profile];
            var clip = actor.clip(profile);
            if (actor.playback.exhausted(clip)) {
                switch (actor.activity) {
                    .idle => |posture| {
                        var chosen = false;
                        for (profile.choices[@backingInt(posture)]) |choice| if (@rem(
                            @as(i16, @bitCast(random.next())),
                            choice.denominator,
                        ) == 0) {
                            shift(actor, profile.gestures[choice.gesture].entry_forward);
                            actor.activity = .{ .gesture = .{ .index = choice.gesture } };
                            chosen = true;
                            break;
                        };
                        if (!chosen and
                            !near.same and
                            !(definition.wake_nearby and near.near)) actor.active = false;
                    },
                    .gesture => |state| {
                        const gesture = profile.gestures[state.index];
                        switch (state.part) {
                            .beginning => if (gesture.waiting != null) {
                                actor.activity.gesture.part = .waiting;
                            } else {
                                shift(actor, gesture.exit_forward);
                                actor.activity = .{ .idle = gesture.finish };
                            },
                            .waiting => if (@rem(
                                @as(i16, @bitCast(random.next())),
                                gesture.release_denominator,
                            ) == 0) {
                                actor.activity.gesture.part = .ending;
                            },
                            .ending => {
                                shift(actor, gesture.exit_forward);
                                actor.activity = .{ .idle = gesture.finish };
                            },
                        }
                    },
                }
                actor.playback = .{};
                _ = try map.handoff(&actor.room, &actor.pose.position);
                clip = actor.clip(profile);
            }
            actor.sound = actor.playback.soundOnEntry(clip);
            _ = actor.playback.advance(clip, &actor.pose);
        }
    }
    pub fn hashInto(self: World, hash: *std.hash.Wyhash) void {
        for (self.actors) |actor| {
            const activity: u64 = switch (actor.activity) {
                .idle => |posture| @backingInt(posture),
                .gesture => |state| 3 + state.index * 3 + @backingInt(state.part),
            };
            for ([_]u64{
                activity,
                @backingInt(actor.room),
                @as(u16, @bitCast(actor.pose.position.x)),
                @as(u16, @bitCast(actor.pose.position.y)),
                @backingInt(actor.pose.facing),
                @backingInt(actor.pose.visual.id),
                @intFromBool(actor.pose.visual.mirrored),
                actor.playback.next_step,
                @intFromBool(actor.active),
            }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
        }
    }
};
