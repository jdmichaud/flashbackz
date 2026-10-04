//! The original close-up view uses a 128x80 scene window, doubled into a letterbox.
const std = @import("std");
const motion = @import("../motion.zig");
pub const Camera = struct {
    active: bool = false,
    origin: motion.Position = .{ .x = 0, .y = 0 },
    fn target(pose: motion.Pose) motion.Position {
        return .{ .x = std.math.clamp(pose.position.x + (if (pose.facing == .right) @as(i16, -12) else -106), 0, 128), .y = std.math.clamp(pose.position.y - 64, 0, 144) };
    }
    pub fn setActive(self: *Camera, active: bool, pose: motion.Pose) void {
        if (active and !self.active) self.origin = target(pose);
        self.active = active;
    }
    pub fn advance(self: *Camera, pose: motion.Pose) void {
        if (!self.active) return;
        const wanted = target(pose);
        const dx = @abs(@as(i32, wanted.x) - self.origin.x);
        const dy = @abs(@as(i32, wanted.y) - self.origin.y);
        const sx: i16 = if (dx < 4) 0 else if (dx < 8) 1 else if (dx < 16) 2 else 4;
        const sy: i16 = if (dy < 4) 0 else if (dy < 8) 2 else if (dy < 16) 4 else 8;
        self.origin.x += if (wanted.x > self.origin.x) sx else if (wanted.x < self.origin.x) -sx else 0;
        self.origin.y += if (wanted.y > self.origin.y) sy else if (wanted.y < self.origin.y) -sy else 0;
    }
    pub fn draw(self: Camera, pixels: []u8, scratch: []u8) !void {
        if (!self.active) return;
        if (pixels.len != 256 * 224 or scratch.len < pixels.len) return error.InvalidZoomFrame;
        @memcpy(scratch[0..pixels.len], pixels);
        @memset(pixels, 0);
        for (0..160) |y| for (0..256) |x| {
            const sx = @as(usize, @intCast(self.origin.x)) + x / 2;
            const sy = @as(usize, @intCast(self.origin.y)) + y / 2;
            pixels[(y + 24) * 256 + x] = scratch[sy * 256 + sx];
        };
    }
};
