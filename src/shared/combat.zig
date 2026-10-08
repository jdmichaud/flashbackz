//! Pose-sensitive hitscan over the shared room/contact grid. A trace reports an event;
//! actor systems own damage, reactions and delivery timing. Allies can obstruct gunfire.
const motion = @import("motion.zig");
const geometry = @import("geometry.zig");
const contacts = @import("contacts.zig");
const terrain = @import("terrain.zig");
pub const Id = enum(u16) { _ };
pub const ProfileId = enum(u16) { _ };
pub const Height = enum { standing, crouched };
pub const Impact = enum { rear_high, rear_low, front_high, front_low };
pub const Vulnerability = ImpactSet;
pub const ImpactSet = struct {
    rear_high: bool = false,
    rear_low: bool = false,
    front_high: bool = false,
    front_low: bool = false,
    pub fn any(self: ImpactSet) bool {
        return self.rear_high or self.rear_low or self.front_high or self.front_low;
    }
    pub fn accepts(self: ImpactSet, impact: Impact) bool {
        return switch (impact) {
            .rear_high => self.rear_high,
            .rear_low => self.rear_low,
            .front_high => self.front_high,
            .front_low => self.front_low,
        };
    }
    pub fn set(self: *ImpactSet, impact: Impact) void {
        switch (impact) {
            .rear_high => self.rear_high = true,
            .rear_low => self.rear_low = true,
            .front_high => self.front_high = true,
            .front_low => self.front_low = true,
        }
    }
};
pub const Category = enum { player, enemy, civilian, mechanism };
pub const Target = struct {
    id: Id,
    footprint: contacts.Footprint,
    facing: motion.Facing,
    vulnerable: Vulnerability,
    active: bool = true,
    category: Category = .enemy,
};
pub const Hit = struct { target: Id, impact: Impact, sender_room: geometry.RoomId };

pub fn impactFor(direction: motion.Facing, target_facing: motion.Facing, height: Height) Impact {
    return if (direction == target_facing) (if (height == .standing) .rear_high else .rear_low) else (if (height == .standing) .front_high else .front_low);
}

pub fn trace(
    view: terrain.View,
    room: geometry.RoomId,
    pose: motion.Pose,
    height: Height,
    range: u16,
    targets: []const Target,
) !?Hit {
    const band = @divTrunc(pose.position.y -% 8, 72);
    if (band < 0 or band > 2) return null;
    const step: i16 = if (pose.facing == .right) 1 else -1;
    var column = ((pose.position.x +% 8) >> 4) +% step;
    var current_room = room;
    const layout: contacts.Layout = .{};
    for (0..range) |_| {
        const cell = try view.geometry.locate(
            current_room,
            column,
            band * 2 + 1,
        ) orelse return null;
        // A target in the first solid cell is considered before the terrain at that cell.
        for (targets) |target| {
            if (!target.active) continue;
            const impact = impactFor(pose.facing, target.facing, height);
            if (!target.vulnerable.accepts(impact)) continue;
            for (0..target.footprint.width) |offset| {
                const occupied = try layout.cell(
                    view.geometry,
                    target.footprint.room,
                    .{
                        .x = target.footprint.position.x +% @as(i16, @intCast(offset)) *% 16,
                        .y = target.footprint.position.y,
                    },
                ) orelse continue;
                if (occupied.room == cell.room and
                    occupied.column == cell.column and
                    occupied.row == band) return .{
                    .target = target.id,
                    .impact = impact,
                    .sender_room = room,
                };
            }
        }
        const material = try view.sample(current_room, column, band * 2 + 1);
        if (material == .solid or (material == .restricted and height == .standing)) return null;
        current_room = cell.room;
        column = @as(i16, @intCast(cell.column)) +% step;
    }
    return null;
}

test "shots skip immune poses, pass low clearance only when crouched, and hit before the wall" {
    const std = @import("std");
    const room: geometry.RoomId = @fromBackingInt(17);
    const empty: [48]bool = @splat(false);
    const rooms = [_]geometry.Room{.{
        .id = room,
        .width = 256,
        .height = 72,
        .columns = 16,
        .rows = 3,
        .blocking = &empty,
        .edges = .{ .left = .blocked, .right = .blocked, .up = .blocked, .down = .blocked },
    }};
    var cells: [48]terrain.Material = @splat(.empty);
    cells[16 + 3] = .restricted;
    const view: terrain.View = .{ .geometry = .{ .rooms = &rooms }, .materials = &cells };
    const pose: motion.Pose = .{
        .position = .{ .x = 0, .y = 70 },
        .facing = .right,
        .visual = .{ .id = @fromBackingInt(0) },
    };
    var targets = [_]Target{
        .{
            .id = @fromBackingInt(5),
            .footprint = .{ .room = room, .position = .{ .x = 32, .y = 70 } },
            .facing = .left,
            .vulnerable = .{ .front_low = true },
        },
        .{
            .id = @fromBackingInt(9),
            .footprint = .{ .room = room, .position = .{ .x = 64, .y = 70 } },
            .facing = .right,
            .vulnerable = .{ .rear_high = true, .rear_low = true },
        },
    };
    try std.testing.expect((try trace(view, room, pose, .standing, 8, &targets)) == null);
    try std.testing.expect((try trace(view, room, pose, .crouched, 1, &targets)) == null);
    const front = (try trace(view, room, pose, .crouched, 2, &targets)).?;
    try std.testing.expectEqual(targets[0].id, front.target);
    try std.testing.expectEqual(Impact.front_low, front.impact);
    targets[0].active = false;
    const rear = (try trace(view, room, pose, .crouched, 8, &targets)).?;
    try std.testing.expectEqual(targets[1].id, rear.target);
    try std.testing.expectEqual(Impact.rear_low, rear.impact);
    cells[16 + 3] = .solid;
    try std.testing.expect((try trace(view, room, pose, .crouched, 8, &targets)) == null);
    targets[1].footprint.position.x = 48;
    try std.testing.expectEqual(
        targets[1].id,
        (try trace(view, room, pose, .standing, 8, &targets)).?.target,
    );
}
