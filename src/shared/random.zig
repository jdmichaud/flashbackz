//! Deterministic shared gameplay randomness. Systems consume one stream in update order.
const std = @import("std");
pub const Stream = struct {
    state: u32 = 0,
    pub fn next(self: *Stream) u16 {
        const high_bit = self.state & 0x80000000 != 0;
        self.state <<= 1;
        if (!high_bit) {
            self.state ^= 0x1d872b41;
        }
        return @truncate(self.state);
    }
};

test "random stream preserves feedback and low-word results at the carry boundary" {
    var stream: Stream = .{};
    try std.testing.expectEqual(@as(u16, 0x2b41), stream.next());
    try std.testing.expectEqual(@as(u32, 0x1d872b41), stream.state);
    stream.state = 0x80008000;
    try std.testing.expectEqual(@as(u16, 0), stream.next());
    try std.testing.expectEqual(@as(u32, 0x00010000), stream.state);
}
