//! Contact-triggered environmental bursts. Room content supplies positions and artwork;
//! fast movement can disturb a surface, while the shared random stream chooses activation.
const std = @import("std");
const motion = @import("motion.zig");
const contacts = @import("contacts.zig");
const geometry = @import("geometry.zig");
pub const Definition = struct { footprint: contacts.Footprint, facing: motion.Facing, palette_bank: u4, behind_player: bool };
pub const Clips = struct { resting: motion.Clip, burst: motion.Clip, alignment_down: i16 = 30, chance: i16 = 5 };
pub const Instance = struct { pose: motion.Pose, playback: motion.Playback = .{}, active: bool = false, sound: ?motion.SoundId = null };
pub const World = struct {
    allocator: std.mem.Allocator,
    instances: []Instance,
    pub fn init(allocator: std.mem.Allocator, definitions: []const Definition, clips: Clips) !World {
        if (definitions.len != 0 and (clips.resting.steps.len == 0 or clips.burst.steps.len == 0)) return error.MissingSurfaceMotion;
        const instances = try allocator.alloc(Instance, definitions.len);
        errdefer allocator.free(instances);
        for (instances, definitions) |*instance, definition| {
            const visual = switch (clips.resting.steps[0]) {
                .hold => return error.MissingSurfaceVisual,
                .frame => |frame| frame.visual,
            };
            instance.* = .{ .pose = .{ .position = definition.footprint.position, .facing = definition.facing, .visual = visual } };
        }
        return .{ .allocator = allocator, .instances = instances };
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.instances);
    }
    pub fn advance(self: *World, definitions: []const Definition, clips: Clips, map: geometry.Map, player: contacts.Footprint, disturbs_surface: bool, random: anytype) !void {
        const layout: contacts.Layout = .{};
        for (self.instances, definitions) |*instance, definition| {
            instance.sound = null;
            var clip = if (instance.active) clips.burst else clips.resting;
            if (instance.playback.exhausted(clip)) {
                if (instance.active) {
                    instance.active = false;
                    instance.pose.position.y -%= clips.alignment_down;
                } else if (definition.footprint.room == player.room and disturbs_surface and try layout.overlaps(map, definition.footprint, player)) {
                    if (@rem(@as(i16, @bitCast(random.next())), clips.chance) == 0) {
                        instance.active = true;
                        instance.pose.position.y +%= clips.alignment_down;
                    }
                }
                instance.playback = .{};
                clip = if (instance.active) clips.burst else clips.resting;
            }
            instance.sound = instance.playback.soundOnEntry(clip);
            _ = instance.playback.advance(clip, &instance.pose);
        }
    }
    pub fn hashInto(self: World, hash: *std.hash.Wyhash) void {
        for (self.instances) |instance| for ([_]u32{ @as(u16, @bitCast(instance.pose.position.x)), @as(u16, @bitCast(instance.pose.position.y)), @intFromBool(instance.active), @intCast(instance.playback.next_step), @backingInt(instance.pose.visual.id), @intFromBool(instance.pose.visual.mirrored) }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u32, value)));
    }
};
