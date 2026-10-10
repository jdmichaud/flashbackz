//! The game's one audio output on the agent's device: opened at the first sound, kept a short
//! queue ahead, cut when a source stops, and silent, not fatal, without a device.
const std = @import("std");
const game = @import("flashbackz");
const backend_mod = @import("backend.zig");
const audio_output = game.audio_output;
const effects = game.sound_effects_player;
const sounds = game.content.sound_effects;

fn testBank(pcm: []i8) sounds.Bank {
    const samples = std.testing.allocator.alloc(sounds.Sample, 1) catch unreachable;
    samples[0] = .{ .pcm = pcm };
    return .{ .allocator = std.testing.allocator, .samples = samples };
}

test "the output opens at the first sound, keeps its lead, and a stopped source takes its queue" {
    var backend = backend_mod.AgentBackend.init(std.testing.allocator, .{});
    defer backend.deinit();
    var p = backend.asPlatform();
    _ = try p.start();
    backend.audio.record = true;
    var output: audio_output.Output = .{};
    output.pump(&p, .{});
    try std.testing.expect(!backend.audio.open);

    var pcm: [600]i8 = @splat(100);
    const bank = testBank(&pcm);
    defer std.testing.allocator.free(bank.samples);
    var sound: effects.Player = .init(null);
    sound.submit(bank, .{ .sound = @fromBackingInt(0) }, .{ .effects = true, .tunes = false });
    output.pump(&p, .{ .level = .{ .sound = &sound, .bank = bank } });
    try std.testing.expect(backend.audio.open);
    try std.testing.expectEqual(@as(u64, audio_output.lead_frames), p.audioStatus().queued_frames);
    try std.testing.expectEqual(@as(i16, 100 * 256), backend.audio.pcm.items[0]);

    // At half volume, the next frames are half as loud.
    backend.advance(10 * std.time.ns_per_ms);
    output.volume = 50;
    const heard = backend.audio.pcm.items.len;
    output.pump(&p, .{ .level = .{ .sound = &sound, .bank = bank } });
    try std.testing.expectEqual(@as(i16, 50 * 256), backend.audio.pcm.items[heard]);

    output.pump(&p, .{});
    try std.testing.expectEqual(@as(u64, 0), p.audioStatus().queued_frames);
    output.close(&p);
    try std.testing.expect(!backend.audio.open);
}

test "without a device the game goes on silent" {
    var backend = backend_mod.AgentBackend.init(std.testing.allocator, .{});
    defer backend.deinit();
    backend.audio.available = false;
    var p = backend.asPlatform();
    _ = try p.start();
    var pcm: [600]i8 = @splat(100);
    const bank = testBank(&pcm);
    defer std.testing.allocator.free(bank.samples);
    var sound: effects.Player = .init(null);
    sound.submit(bank, .{ .sound = @fromBackingInt(0) }, .{ .effects = true, .tunes = false });
    var output: audio_output.Output = .{};
    for (0..3) |_| output.pump(&p, .{ .level = .{ .sound = &sound, .bank = bank } });
    try std.testing.expect(!backend.audio.open);
    try std.testing.expectEqual(@as(u64, 0), backend.calls.audio_queue);
}
