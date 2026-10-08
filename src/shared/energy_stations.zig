//! Passive recharge points. Items own their use/completion effects; stations provide
//! contact, original animated artwork and the nearby interaction hint.
const std = @import("std");
const motion = @import("motion.zig");
const geometry = @import("geometry.zig");
const contacts = @import("contacts.zig");
const activation = @import("activation.zig");
const world_props = @import("world_props.zig");
pub const Definition = struct {
    footprint: contacts.Footprint,
    facing: motion.Facing,
    palette_bank: u4,
    layer: world_props.Layer,
    idle: motion.Clip,
    initially_active: bool,
    wake_when_near: bool,
    hint: ?motion.VisualId,
    label: []const u8,
};
pub const Instance = struct {
    pose: motion.Pose,
    active: bool,
    playback: motion.Playback = .{},
    sound: ?motion.SoundId = null,
};
pub const World = struct {
    allocator: std.mem.Allocator,
    instances: []Instance,
    candidate: ?usize = null,
    pub fn init(allocator: std.mem.Allocator, definitions: []const Definition) !World {
        const instances = try allocator.alloc(Instance, definitions.len);
        errdefer allocator.free(instances);
        for (instances, definitions) |*instance, definition| {
            if (definition.idle.steps.len == 0) return error.MissingStationAnimation;
            const visual = switch (definition.idle.steps[0]) {
                .frame => |frame| frame.visual,
                .hold => return error.MissingStationVisual,
            };
            instance.* = .{
                .active = definition.initially_active,
                .pose = .{
                    .position = definition.footprint.position,
                    .facing = definition.facing,
                    .visual = .{
                        .id = visual.id,
                        .mirrored = visual.mirrored != (definition.facing == .left),
                    },
                },
            };
        }
        return .{ .allocator = allocator, .instances = instances };
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.instances);
    }
    pub fn prepare(
        self: *World,
        definitions: []const Definition,
        map: geometry.Map,
        player: contacts.Footprint,
    ) !void {
        self.candidate = null;
        const layout: contacts.Layout = .{};
        for (definitions, 0..) |definition, index| if (try layout.overlaps(
            map,
            player,
            definition.footprint,
        )) {
            self.candidate = index;
        };
    }
    pub fn advance(
        self: *World,
        definitions: []const Definition,
        map: geometry.Map,
        player_room: geometry.RoomId,
    ) !void {
        for (self.instances, definitions) |*instance, definition| {
            instance.sound = null;
            const near = try activation.around(
                map,
                player_room,
                definition.footprint.room,
                definition.footprint.position.y,
            );
            if (definition.wake_when_near and near.wake) instance.active = true;
            if (!instance.active) continue;
            if (instance.playback.exhausted(definition.idle)) {
                if (!near.same and
                    !(definition.wake_when_near and near.near)) instance.active = false;
                instance.playback = .{};
            }
            instance.sound = instance.playback.soundOnEntry(definition.idle);
            _ = instance.playback.advance(definition.idle, &instance.pose);
        }
    }
    pub fn hashInto(self: World, hash: *std.hash.Wyhash) void {
        for (self.instances) |instance| for ([_]u64{
            @intFromBool(instance.active),
            instance.playback.next_step,
            @backingInt(instance.pose.visual.id),
            @intFromBool(instance.pose.visual.mirrored),
        }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
    }
};
