//! One-shot contact destinations announce arrival, then signal completion after their clips.
const std = @import("std");
const motion = @import("motion.zig");
const geometry = @import("geometry.zig");
const contacts = @import("contacts.zig");
const Circuit = @import("world_props.zig").CircuitId;
pub const Phase = enum { waiting, announcing, completing, removed };
pub const Definition = struct {
    footprint: contacts.Footprint,
    category: contacts.Kind,
    clips: [3]motion.Clip,
    notice: @import("world_messages.zig").Id,
    begin: Circuit,
    complete: Circuit,
    priority: u16,
    initially_active: bool,
    wake_on_contact: bool,
};
pub const Instance = struct {
    phase: Phase = .waiting,
    playback: motion.Playback = .{},
    active: bool,
};
pub const World = struct {
    allocator: std.mem.Allocator,
    instances: []Instance,
    pulses: []Circuit,
    pulse_count: usize = 0,
    notice: ?@import("world_messages.zig").Request = null,
    pub fn init(allocator: std.mem.Allocator, definitions: []const Definition) !World {
        const instances = try allocator.alloc(Instance, definitions.len);
        errdefer allocator.free(instances);
        for (
            instances,
            definitions,
        ) |*instance, definition| instance.* = .{ .active = definition.initially_active };
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
    pub fn advance(
        self: *World,
        definitions: []const Definition,
        map: geometry.Map,
        player_room: geometry.RoomId,
        participants: []const contacts.Participant,
        icon: motion.VisualId,
    ) !void {
        self.pulse_count = 0;
        self.notice = null;
        const layout: contacts.Layout = .{};
        for (self.instances, definitions) |*instance, definition| {
            if (instance.phase == .removed) continue;
            var occupied = false;
            if (instance.active or
                definition.footprint.room == player_room) for (participants) |participant|
            {
                if (participant.kind != definition.category or
                    !participant.ordinary_contact or
                    (!participant.active and participant.footprint.room != player_room)) continue;
                if (try layout.overlaps(map, definition.footprint, participant.footprint)) {
                    occupied = true;
                    break;
                }
            };
            if (occupied and definition.wake_on_contact) instance.active = true;
            if (!instance.active) continue;
            var clip = definition.clips[@backingInt(instance.phase)];
            if (instance.playback.exhausted(clip)) {
                switch (instance.phase) {
                    .waiting => if (occupied) {
                        instance.phase = .announcing;
                        self.pulses[self.pulse_count] = definition.begin;
                        self.pulse_count += 1;
                    } else {
                        instance.active = false;
                    },
                    .announcing => {
                        self.notice = .{
                            .message = definition.notice,
                            .icon = icon,
                            .priority = definition.priority,
                        };
                        instance.phase = .completing;
                    },
                    .completing => {
                        self.pulses[self.pulse_count] = definition.complete;
                        self.pulse_count += 1;
                        instance.phase = .removed;
                        instance.active = false;
                    },
                    .removed => unreachable,
                }
                instance.playback = .{};
                if (instance.phase == .removed) continue;
                clip = definition.clips[@backingInt(instance.phase)];
            }
            // These destination clips are invisible, stationary cadence markers.
            var pose: motion.Pose = .{
                .position = definition.footprint.position,
                .facing = .right,
                .visual = .{ .id = @fromBackingInt(0) },
            };
            _ = instance.playback.advance(clip, &pose);
        }
    }
    pub fn hashInto(self: World, hash: *std.hash.Wyhash) void {
        for (self.instances) |instance| for ([_]u64{
            @backingInt(instance.phase),
            instance.playback.next_step,
            @intFromBool(instance.active),
        }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
    }
};
