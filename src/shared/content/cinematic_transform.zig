//! Fixed-point projection used when importing original vector content. Playback only sees
//! the resulting screen geometry. Degree ties are explicit, so host floating-point rounding
//! cannot change the original Q8 table's integer-valued boundary cases.
const std = @import("std");
const Point = indexed_shapes.Point;
const indexed_shapes = @import("../render/indexed_shapes.zig");

/// The sine of each whole degree in Q8: 256 is 1.0.
const sine_table: [360]i16 = table: {
    @setEvalBranchQuota(200000);
    var values: [360]i16 = undefined;
    for (&values, 0..) |*value, degrees| {
        value.* = switch (degrees) {
            0, 180 => 0,
            30, 150 => 127,
            90 => 256,
            210 => -128,
            270 => -256,
            330 => -127,
            else => @intFromFloat(
                @sin(@as(f64, @floatFromInt(degrees)) * std.math.pi / 180.0) * 256.0,
            ),
        };
    }
    break :table values;
};

pub fn sine(degrees: u16) !i16 {
    if (degrees >= sine_table.len) return error.UnsupportedCinematicAngle;
    return sine_table[degrees];
}

pub fn cosine(degrees: u16) !i16 {
    if (degrees >= 360) return error.UnsupportedCinematicAngle;
    // The cosine of 300 is 128, not the table's sine of 30 (127).
    if (degrees == 300) return 128;
    return sine((degrees + 90) % 360);
}

/// A 2 x 2 matrix in Q8 (256 is 1.0).
pub const Projection = struct {
    xx: i32,
    xy: i32,
    yx: i32,
    yy: i32,

    /// The three angles are whole degrees, 0-359. The angles 0, 180 and 90 give the identity.
    pub fn fromDegrees(turn: u16, vertical: u16, horizontal: u16) !Projection {
        const sa: i32 = try sine(turn);
        const ca: i32 = try cosine(turn);
        const sb: i32 = try sine(vertical);
        const cb: i32 = try cosine(vertical);
        const sc: i32 = try sine(horizontal);
        const cc: i32 = try cosine(horizontal);
        return .{
            .xx = ((ca * cb) >> 8) - ((((cc * sa) >> 8) * sb) >> 8),
            .xy = ((sa * cb) >> 8) + ((((cc * ca) >> 8) * sb) >> 8),
            .yx = (sc * sa) >> 8,
            .yy = (-sc * ca) >> 8,
        };
    }

    /// Moves `input` about `pivot`. The matrix acts on `pivot - input`, so the identity has
    /// -256 on its diagonal.
    pub fn point(self: Projection, input: Point, pivot: Point) Point {
        const dx: i32 = @as(i32, pivot.x) - input.x;
        const dy: i32 = @as(i32, pivot.y) - input.y;
        return .{
            .x = @truncate(@as(i32, pivot.x) + ((dx * self.xx + dy * self.xy) >> 8)),
            .y = @truncate(@as(i32, pivot.y) + ((dx * self.yx + dy * self.yy) >> 8)),
        };
    }
};

test "projection identity, quarter turn, and quantized trigonometric ties" {
    const identity = try Projection.fromDegrees(0, 180, 90);
    const pivot: Point = .{ .x = 2, .y = 2 };
    try std.testing.expectEqual(
        Point{ .x = 8, .y = 2 },
        identity.point(.{ .x = 8, .y = 2 }, pivot),
    );
    const quarter = try Projection.fromDegrees(90, 180, 90);
    try std.testing.expectEqual(
        Point{ .x = 2, .y = -4 },
        quarter.point(.{ .x = 8, .y = 2 }, pivot),
    );
    try std.testing.expectEqual(@as(i16, 127), try cosine(60));
    try std.testing.expectEqual(@as(i16, -128), try cosine(120));
    try std.testing.expectEqual(@as(i16, -127), try sine(330));
    try std.testing.expectError(error.UnsupportedCinematicAngle, sine(360));
}
