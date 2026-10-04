//! ANI compatibility records are resolved into independently owned motion clips. Original
//! animation and sprite indices stop at this boundary; playback sees opaque visual IDs.
const std = @import("std");
const motion = @import("../motion.zig");

pub const VisualKind = enum { sprite, composition };
pub const SourceFrame = union(enum) {
    hold,
    frame: struct { index: u15, mirrored: bool, dx: i8, dy: i8 },
};

pub const SourceClip = struct {
    allocator: std.mem.Allocator,
    frames: []SourceFrame,
    kind: VisualKind,
    sound: ?u8,
    /// Preserved by import for further recovery; not used as an engine timer or flag word.
    header_metadata: u8,

    pub fn deinit(self: *SourceClip) void {
        self.allocator.free(self.frames);
        self.* = undefined;
    }

    /// Resolver has `resolve(kind, source_index) !VisualId`. A content pack owns that
    /// mapping and all referenced art; adding a clip does not alter the playback system.
    pub fn resolve(self: SourceClip, allocator: std.mem.Allocator, resolver: anytype) !OwnedClip {
        const steps = try allocator.alloc(motion.Step, self.frames.len);
        errdefer allocator.free(steps);
        for (self.frames, steps) |source, *step| {
            step.* = switch (source) {
                .hold => .hold,
                .frame => |frame| .{
                    .frame = .{
                        // Original unreflected actor art faces left. Modern clips describe
                        // a right-facing actor; playback reflects both motion and art for left.
                        .visual = .{ .id = try resolver.resolve(self.kind, frame.index), .mirrored = !frame.mirrored },
                        .forward = -@as(i16, frame.dx),
                        .down = frame.dy,
                    },
                },
            };
        }
        return .{ .allocator = allocator, .steps = steps, .presses_floor_switches = self.header_metadata == 0 or self.header_metadata == 1 or self.header_metadata == 5 };
    }
};

pub const OwnedClip = struct {
    allocator: std.mem.Allocator,
    steps: []motion.Step,
    presses_floor_switches: bool,

    pub fn deinit(self: *OwnedClip) void {
        self.allocator.free(self.steps);
        self.* = undefined;
    }

    pub fn clip(self: *const OwnedClip) motion.Clip {
        return .{ .steps = self.steps, .presses_floor_switches = self.presses_floor_switches };
    }
};

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, index: u16) !SourceClip {
    if (bytes.len < 2) return error.TruncatedAnimationDirectory;
    const count = std.mem.readInt(u16, bytes[0..2], .little);
    const directory_end = 2 + @as(usize, count) * 2;
    if (directory_end > bytes.len) return error.TruncatedAnimationDirectory;
    if (index >= count) return error.MissingAnimation;
    const offset = 2 + @as(usize, std.mem.readInt(u16, bytes[2 + @as(usize, index) * 2 ..][0..2], .little));
    // Trailing unused entries point exactly one byte past the file, not to an empty clip.
    if (offset == bytes.len) return error.MissingAnimation;
    if (offset < directory_end or offset > bytes.len or bytes.len - offset < 6) return error.InvalidAnimationOffset;
    const frame_count = std.mem.readInt(u16, bytes[offset..][0..2], .little);
    if (frame_count == 0 or frame_count > 255) return error.InvalidAnimationLength;
    if (@as(usize, frame_count) * 4 > bytes.len - offset - 6) return error.TruncatedAnimation;
    const form = std.mem.readInt(u16, bytes[offset + 4 ..][0..2], .little);
    if (form > 1) return error.UnknownAnimationVisualKind;
    const frames = try allocator.alloc(SourceFrame, frame_count);
    for (frames, 0..) |*frame, i| {
        const record = bytes[offset + 6 + i * 4 ..][0..4];
        const visual = std.mem.readInt(u16, record[0..2], .little);
        frame.* = if (visual == 0xffff) .hold else .{ .frame = .{
            .index = @truncate(visual),
            .mirrored = visual & 0x8000 != 0,
            .dx = @bitCast(record[2]),
            .dy = @bitCast(record[3]),
        } };
    }
    const sound = bytes[offset + 2];
    return .{
        .allocator = allocator,
        .frames = frames,
        .kind = if (form == 0) .sprite else .composition,
        .sound = if (sound == 0) null else sound - 1,
        .header_metadata = bytes[offset + 3],
    };
}

test "binary animation resolves to an independent clip and sentinel frames hold" {
    const bytes = [_]u8{ 1, 0, 2, 0, 2, 0, 3, 5, 0, 0, 9, 128, 255, 2, 255, 255, 100, 100 };
    var source = try decode(std.testing.allocator, &bytes, 0);
    defer source.deinit();
    try std.testing.expectEqual(@as(?u8, 2), source.sound);
    try std.testing.expectEqual(@as(u8, 5), source.header_metadata);
    const Resolver = struct {
        pub fn resolve(_: @This(), kind: VisualKind, index: u15) !motion.VisualId {
            try std.testing.expectEqual(.sprite, kind);
            try std.testing.expectEqual(@as(u15, 9), index);
            return @fromBackingInt(42);
        }
    };
    var owned = try source.resolve(std.testing.allocator, Resolver{});
    defer owned.deinit();
    var pose: motion.Pose = .{ .position = .{ .x = 10, .y = 20 }, .facing = .left, .visual = .{ .id = @fromBackingInt(0) } };
    var playback: motion.Playback = .{};
    _ = playback.advance(owned.clip(), &pose);
    try std.testing.expectEqual(motion.Position{ .x = 9, .y = 22 }, pose.position);
    try std.testing.expectEqual(@as(motion.VisualId, @fromBackingInt(42)), pose.visual.id);
    try std.testing.expect(pose.visual.mirrored);
    const held = pose;
    _ = playback.advance(owned.clip(), &pose);
    try std.testing.expectEqualDeep(held, pose);
}

test "missing and malformed animations are distinguished before allocating frames" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.TruncatedAnimationDirectory, decode(a, &.{ 1, 0 }, 0));
    try std.testing.expectError(error.MissingAnimation, decode(a, &.{ 1, 0, 2, 0 }, 0));
    try std.testing.expectError(error.InvalidAnimationOffset, decode(a, &.{ 1, 0, 0, 0 }, 0));
    try std.testing.expectError(error.InvalidAnimationLength, decode(a, &.{ 1, 0, 2, 0, 0, 0, 0, 0, 0, 0 }, 0));
    try std.testing.expectError(error.TruncatedAnimation, decode(a, &.{ 1, 0, 2, 0, 1, 0, 0, 0, 0, 0 }, 0));
}
