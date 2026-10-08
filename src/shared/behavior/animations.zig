//! A level's animations, read in place from the original animation file. A state's
//! animation is a list of frames, each with a sprite and a movement, plus a sound to play
//! on entry and a pose tag that contact checks can test.
const std = @import("std");

pub const Frame = struct {
    /// Sprite number; `null` frames show nothing new.
    sprite: ?u16,
    mirrored: bool,
    /// Toward the character's back, as the original stores it.
    dx: i8,
    dy: i8,
};

pub const Animation = struct {
    frames: []const u8,
    /// Sound played when the animation starts, if any.
    sound: ?u8,
    /// Contact pose tag (header byte 3), tested by `touching_in_pose`.
    pose: u8,
    composition: bool,

    pub fn count(self: Animation) usize {
        return self.frames.len / 4;
    }

    pub fn frame(self: Animation, index: usize) Frame {
        const record = self.frames[index * 4 ..][0..4];
        const visual = std.mem.readInt(u16, record[0..2], .little);
        return .{
            .sprite = if (visual == 0xffff) null else visual & 0x7fff,
            .mirrored = visual != 0xffff and visual & 0x8000 != 0,
            .dx = @bitCast(record[2]),
            .dy = @bitCast(record[3]),
        };
    }
};

pub const Animations = struct {
    bytes: []const u8,

    pub fn init(bytes: []const u8) !Animations {
        if (bytes.len < 2) return error.TruncatedAnimationDirectory;
        const count = std.mem.readInt(u16, bytes[0..2], .little);
        if (2 + @as(usize, count) * 2 > bytes.len) return error.TruncatedAnimationDirectory;
        return .{ .bytes = bytes };
    }

    pub fn get(self: Animations, id: u16) !Animation {
        const count = std.mem.readInt(u16, self.bytes[0..2], .little);
        if (id >= count) return error.MissingAnimation;
        const entry = self.bytes[2 + @as(usize, id) * 2 ..][0..2];
        const offset = 2 + @as(usize, std.mem.readInt(u16, entry, .little));
        const fits = offset <= self.bytes.len and self.bytes.len - offset >= 6;
        if (!fits) return error.InvalidAnimationOffset;
        const header = self.bytes[offset..][0..6];
        const frames: usize = std.mem.readInt(u16, header[0..2], .little);
        const available = self.bytes.len - offset - 6;
        if (frames == 0 or frames * 4 > available) return error.InvalidAnimationLength;
        return .{
            .frames = self.bytes[offset + 6 ..][0 .. frames * 4],
            .sound = if (header[2] == 0) null else header[2] - 1,
            .pose = header[3],
            .composition = std.mem.readInt(u16, header[4..6], .little) != 0,
        };
    }
};

test "animations read frames, sound and pose in place" {
    const bytes = [_]u8{ 1, 0, 2, 0 } ++ [_]u8{ 2, 0, 3, 5, 0, 0 } ++
        [_]u8{ 9, 0x80, 0xfe, 2 } ++ [_]u8{ 0xff, 0xff, 1, 0 };
    const animations = try Animations.init(&bytes);
    const walk = try animations.get(0);
    try std.testing.expectEqual(@as(usize, 2), walk.count());
    try std.testing.expectEqual(@as(?u8, 2), walk.sound);
    try std.testing.expectEqual(@as(u8, 5), walk.pose);
    try std.testing.expectEqual(
        Frame{ .sprite = 9, .mirrored = true, .dx = -2, .dy = 2 },
        walk.frame(0),
    );
    try std.testing.expectEqual(@as(?u16, null), walk.frame(1).sprite);
    try std.testing.expectError(error.MissingAnimation, animations.get(1));
}
