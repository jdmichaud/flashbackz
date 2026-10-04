//! Playback supplies sampled controls to the ordinary world and inventory input paths.
//! A recording describes inputs, never actor positions or scripted gameplay outcomes.
const std = @import("std");
pub const Sample = struct {
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
    use_item: bool = false,
    weapon: bool = false,
    action: bool = false,
    inventory: bool = false,
};
pub const Playback = struct {
    samples: []const Sample,
    cursor: usize = 0,
    pub fn next(self: *Playback) ?Sample {
        if (self.cursor == self.samples.len) return null;
        const sample = self.samples[self.cursor];
        self.cursor += 1;
        return sample;
    }
};

test "playback exhaustion is stable and never repeats the final control" {
    const samples = [_]Sample{ .{ .right = true }, .{} };
    var playback: Playback = .{ .samples = &samples };
    try std.testing.expect(playback.next().?.right);
    try std.testing.expect(!playback.next().?.right);
    try std.testing.expect(playback.next() == null);
    try std.testing.expect(playback.next() == null);
    try std.testing.expectEqual(@as(usize, 2), playback.cursor);
}
