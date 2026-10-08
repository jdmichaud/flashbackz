//! A talking trader with authored idle choices and ordered payment/grant events.
const std = @import("std");
const motion = @import("../motion.zig");
const geometry = @import("../geometry.zig");
const contacts = @import("../contacts.zig");
const equipment = @import("../equipment.zig");
const messages = @import("../world_messages.zig");
const Circuit = world_props.CircuitId;
const activation = @import("../activation.zig");
const perception = @import("perception.zig");
const story_cue = @import("../story_cue.zig");
const world_props = @import("../world_props.zig");
pub const Phase = enum { watching, idle, looking, fidgeting, looking_back, talking, selling };
pub const Profile = struct {
    clips: [7]motion.Clip,
    sight_cells: u8,
    look_chance: i16,
    fidget_chance: i16,
    introduction: messages.Id,
    thanks: messages.Id,
    payment_movie: story_cue.Cue,
};
pub const Definition = struct {
    profile: usize,
    footprint: contacts.Footprint,
    facing: motion.Facing,
    palette_bank: u4,
    behind_player: bool,
    initially_active: bool,
    wake_nearby: bool,
    accepts_signals: bool,
    interaction_priority: u16,
    hint: motion.VisualId,
    label: []const u8,
    price: i16,
    debit: i16,
    purse: equipment.ItemHandle,
    outputs: []const Circuit,
};
pub const Binding = struct {
    item: equipment.ItemHandle,
    trader: usize,
    next_step: bool,
};
pub const Actor = struct {
    pose: motion.Pose,
    contact: contacts.Footprint,
    phase: Phase = .watching,
    playback: motion.Playback = .{},
    active: bool,
    ready: bool = false,
    pending: bool = false,
    sound: ?motion.SoundId = null,
};
pub const World = struct {
    allocator: std.mem.Allocator,
    actors: []Actor,
    candidate: ?usize = null,
    notice: ?messages.Id = null,
    notice_priority: u16 = 0,
    movie: ?story_cue.Cue = null,
    pulses: []Circuit,
    pulse_count: usize = 0,
    pub fn init(
        allocator: std.mem.Allocator,
        definitions: []const Definition,
        profiles: []const Profile,
    ) !World {
        const actors = try allocator.alloc(Actor, definitions.len);
        errdefer allocator.free(actors);
        var outputs: usize = 0;
        for (actors, definitions) |*actor, definition| {
            const clip = profiles[definition.profile].clips[0];
            if (clip.steps.len == 0) return error.MissingTraderAnimation;
            const visual = switch (clip.steps[0]) {
                .frame => |frame| frame.visual,
                .hold => return error.MissingTraderVisual,
            };
            actor.* = .{
                .pose = .{
                    .position = definition.footprint.position,
                    .facing = definition.facing,
                    .visual = .{
                        .id = visual.id,
                        .mirrored = visual.mirrored != (definition.facing == .left),
                    },
                },
                .contact = definition.footprint,
                .active = definition.initially_active,
            };
            outputs += definition.outputs.len;
        }
        return .{
            .allocator = allocator,
            .actors = actors,
            .pulses = try allocator.alloc(Circuit, outputs),
        };
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.actors);
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
        self.movie = null;
        self.pulse_count = 0;
        const layout: contacts.Layout = .{};
        for (self.actors, definitions, 0..) |*actor, definition, index| {
            actor.ready = actor.pending;
            actor.pending = false;
            actor.sound = null;
            actor.contact = definition.footprint;
            actor.contact.position = actor.pose.position;
            const near = try activation.around(
                map,
                player.room,
                definition.footprint.room,
                actor.pose.position.y,
            );
            if (definition.wake_nearby and near.wake) actor.active = true;
            if (try layout.overlaps(map, player, actor.contact)) self.candidate = index;
        }
    }
    pub fn offerPayment(
        self: *World,
        definitions: []const Definition,
        bindings: []const Binding,
        item: equipment.ItemHandle,
        amount: i16,
    ) bool {
        const index = self.candidate orelse return false;
        if (amount < definitions[index].price) return false;
        const binding = for (bindings) |entry| {
            if (entry.trader == index and entry.item.eql(item)) break entry;
        } else return false;
        if (self.actors[index].active or definitions[index].accepts_signals) {
            if (binding.next_step) self.actors[index].pending = true else self.actors[index].ready = true;
        }
        return true;
    }
    fn chance(random: anytype, denominator: i16) bool {
        return denominator != 0 and @rem(@as(i16, @bitCast(random.next())), denominator) == 0;
    }
    fn accept(
        self: *World,
        actor: *Actor,
        definition: Definition,
        profile: Profile,
        items: *equipment.Loadout,
    ) !void {
        try items.debit(definition.purse, definition.debit);
        self.movie = profile.payment_movie;
        actor.phase = .selling;
    }
    pub fn advance(
        self: *World,
        definitions: []const Definition,
        profiles: []const Profile,
        map: geometry.Map,
        player: contacts.Footprint,
        talk: bool,
        items: *equipment.Loadout,
        random: anytype,
    ) !void {
        for (self.actors, definitions, 0..) |*actor, definition, index| {
            const near = try activation.around(
                map,
                player.room,
                definition.footprint.room,
                actor.pose.position.y,
            );
            if (definition.wake_nearby and
                near.wake or
                actor.ready and
                    definition.accepts_signals) actor.active = true;
            if (!actor.active) continue;
            const profile = profiles[definition.profile];
            var clip = profile.clips[@backingInt(actor.phase)];
            const speaking = talk and self.candidate == index;
            if (actor.phase != .selling and
                (actor.ready or
                    speaking and
                        actor.phase != .talking)) actor.playback.completeDisplacement(
                clip,
                &actor.pose,
            );
            if (actor.playback.exhausted(clip)) {
                const observer: perception.Observer = .{
                    .room = definition.footprint.room,
                    .pose = actor.pose,
                };
                const front = if (try perception.scanObjects(
                    map,
                    player.room,
                    observer,
                    &.{player},
                    false,
                )) |distance| distance <= profile.sight_cells else false;
                const back = if (try perception.scanObjects(
                    map,
                    player.room,
                    observer,
                    &.{player},
                    true,
                )) |distance| distance <= profile.sight_cells else false;
                switch (actor.phase) {
                    .watching => {
                        if (!near.same) {
                            actor.phase = .idle;
                            if (!(definition.wake_nearby and near.near)) actor.active = false;
                        } else if (speaking) actor.phase = .talking else if (actor.ready) try self.accept(
                            actor,
                            definition,
                            profile,
                            items,
                        ) else if (!front) actor.phase = .idle;
                    },
                    .idle => {
                        if (!near.same) actor.phase = .watching else if (speaking) actor.phase = .talking else if (actor.ready) try self.accept(
                            actor,
                            definition,
                            profile,
                            items,
                        ) else if (chance(
                            random,
                            profile.look_chance,
                        )) actor.phase = .looking else if (chance(
                            random,
                            profile.fidget_chance,
                        )) actor.phase = .fidgeting else if (back) actor.phase = .looking_back;
                    },
                    .looking_back => {
                        if (!near.same) actor.phase = .idle else if (speaking) actor.phase = .talking else if (actor.ready) try self.accept(
                            actor,
                            definition,
                            profile,
                            items,
                        ) else if (front) actor.phase = .idle;
                    },
                    .looking => {
                        if (actor.ready) try self.accept(
                            actor,
                            definition,
                            profile,
                            items,
                        ) else if (speaking) actor.phase = .talking else actor.phase = .idle;
                    },
                    .fidgeting => {
                        if (speaking) actor.phase = .talking else if (actor.ready) try self.accept(
                            actor,
                            definition,
                            profile,
                            items,
                        ) else actor.phase = .idle;
                    },
                    .talking => {
                        if (actor.ready) try self.accept(actor, definition, profile, items) else {
                            actor.phase = .idle;
                            self.notice = profile.introduction;
                            self.notice_priority = definition.interaction_priority;
                        }
                    },
                    .selling => {
                        actor.phase = .idle;
                        self.notice = profile.thanks;
                        self.notice_priority = definition.interaction_priority;
                        for (definition.outputs) |output| {
                            self.pulses[self.pulse_count] = output;
                            self.pulse_count += 1;
                        }
                    },
                }
                actor.playback = .{};
                clip = profile.clips[@backingInt(actor.phase)];
            }
            actor.sound = actor.playback.soundOnEntry(clip);
            _ = actor.playback.advance(clip, &actor.pose);
            actor.ready = false;
        }
    }
    pub fn hashInto(self: World, hash: *std.hash.Wyhash) void {
        for (self.actors) |actor| for ([_]u64{
            @backingInt(actor.phase),
            actor.playback.next_step,
            @intFromBool(actor.active),
            @intFromBool(actor.ready),
            @intFromBool(actor.pending),
        }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
    }
};
