//! User master volume applies after synthesis and mixing, preserving their timing and state.
const std = @import("std");
const platform = @import("../platform.zig");

/// How far ahead of the device music and effects keep their queue: 50 ms. A device takes a
/// period at a time (SDL's 1,024 frames are 23 ms at 44.1 kHz), and the queue is topped up
/// once a host frame, so less than a period plus a frame leaves the device short, and SDL plays
/// silence for the rest of the period.
pub fn leadFrames(rate: u32) u32 {
    return rate / 20;
}

pub fn queue(p: *platform.Platform, samples: []const i16, percent: u8) !usize {
    if (percent >= 100) return p.audioQueue(samples);
    var scaled: [2048]i16 = undefined;
    const count = @min(samples.len, scaled.len);
    scale(samples[0..count], scaled[0..count], percent);
    return p.audioQueue(scaled[0..count]);
}

fn scale(input: []const i16, output: []i16, percent: u8) void {
    for (input, output) |sample, *result| result.* = @intCast(@divTrunc(
        @as(i32, sample) * @min(percent, 100),
        100,
    ));
}

test "master volume preserves full range, halves both signs and mutes" {
    const input = [_]i16{ -32768, -101, 0, 101, 32767 };
    var output: [5]i16 = undefined;
    scale(&input, &output, 100);
    try std.testing.expectEqualSlices(i16, &input, &output);
    scale(&input, &output, 50);
    try std.testing.expectEqualSlices(i16, &.{ -16384, -50, 0, 50, 16383 }, &output);
    scale(&input, &output, 0);
    try std.testing.expectEqualSlices(i16, &.{ 0, 0, 0, 0, 0 }, &output);
}
