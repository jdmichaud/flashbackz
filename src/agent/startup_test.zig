//! Incomplete floppy resources fail explicitly; menu preview remains independently usable.
const std = @import("std");
const game = @import("flashbackz");
const backend_mod = @import("backend.zig");

test "floppy menu preview rejects missing introduction and wake-up resources" {
    const allocator = std.testing.allocator;
    var source = game.memory.MemoryAssetSource.init(allocator);
    defer source.deinit();
    const pixels = try allocator.alloc(u8, 57344);
    defer allocator.free(pixels);
    @memset(pixels, 0);
    const palette: [768]u8 = @splat(0);
    const font: [3360]u8 = @splat(0);
    try source.add("DATA/MENU1.MAP", pixels);
    try source.add("DATA/MENU1.PAL", &palette);
    try source.add("DATA/MENU3.MAP", pixels);
    try source.add("DATA/MENU3.PAL", &palette);
    try source.add("DATA/FB_TXT.FNT", &font);
    try std.testing.expectError(
        error.NotFound,
        game.Game.init(allocator, source.assetSource(), null),
    );
    var preview = try game.Game.initWithEntry(
        allocator,
        source.assetSource(),
        null,
        null,
        .menu_development,
    );
    defer preview.deinit();
    const front = &preview.scene.menu;
    try front.event(.{ .time_ns = 0, .payload = .{ .key_down = .{ .key = .down } } });
    try front.event(.{ .time_ns = 1, .payload = .{ .key_down = .{ .key = .enter } } });
    try std.testing.expectEqual(game.front_end.View.skill, front.view);
    try front.event(.{ .time_ns = 2, .payload = .{ .key_down = .{ .key = .up } } });
    try front.event(.{ .time_ns = 3, .payload = .{ .key_down = .{ .key = .enter } } });
    try std.testing.expectEqual(game.settings.Difficulty.easy, front.difficulty);
    try std.testing.expectEqual(game.front_end.View.main, front.view);
    try std.testing.expectError(error.NotFound, front.start());
}

test "normal startup completes three vector chapters and skipping introduction reaches menu" {
    const allocator = std.testing.allocator;
    var source = game.memory.MemoryAssetSource.init(allocator);
    defer source.deinit();
    const pixels = try allocator.alloc(u8, 57344);
    defer allocator.free(pixels);
    @memset(pixels, 0);
    const palette: [768]u8 = @splat(0);
    const font: [3360]u8 = @splat(0);
    try source.add("DATA/MENU1.MAP", pixels);
    try source.add("DATA/MENU1.PAL", &palette);
    try source.add("DATA/FB_TXT.FNT", &font);
    const commands = [_]u8{ 0, 0, 0, 255 };
    const polygons: [20]u8 = @splat(0);
    try source.add("DATA/LOGOS.CMD", &commands);
    try source.add("DATA/LOGOS.POL", &polygons);
    try source.add("DATA/INTRO1.CMD", &commands);
    try source.add("DATA/INTRO1.POL", &polygons);
    try source.add("DATA/INTRO2.CMD", &commands);
    try source.add("DATA/INTRO2.POL", &polygons);
    var profile: [753]u8 = @splat(0);
    profile[544] = 7;
    profile[549] = 12;
    @memcpy(profile[550..558], "TEST.MID");
    const midi = [_]u8{
        'M',
        'T',
        'h',
        'd',
        0,
        0,
        0,
        6,
        0,
        0,
        0,
        1,
        0,
        96,
        'M',
        'T',
        'r',
        'k',
        0,
        0,
        0,
        4,
        0,
        255,
        47,
        0,
    };
    try source.add("DATA/TEST.MID", &midi);
    try source.add("DATA/PRESENT3.PRF", &profile);
    try source.add("DATA/INTROL3.PRF", &profile);
    try source.add("DATA/OPTION3.PRF", &profile);
    const Backend = backend_mod.AgentBackend;
    var backend = Backend.init(allocator, .{});
    defer backend.deinit();
    var platform = backend.asPlatform();
    var app = try game.Game.init(allocator, source.assetSource(), null);
    defer app.deinit();
    var first = false;
    var second = false;
    for (0..20) |_| {
        _ = try app.update(&platform);
        if (app.scene.menu.stage == .introduction) {
            if (app.scene.menu.introduction_part == .first) first = true else second = true;
        }
        backend.advance(100_000_000);
    }
    try std.testing.expect(first and second);
    try std.testing.expect(backend.calls.audio_queue > 0);
    try std.testing.expectEqual(game.front_end.Stage.menu, app.scene.menu.stage);
    try app.scene.menu.intro();
    _ = try app.update(&platform);
    try backend.inject(.{
        .time_ns = backend.clock_ns,
        .payload = .{ .key_down = .{ .key = .tab } },
    });
    _ = try app.update(&platform);
    try std.testing.expectEqual(game.front_end.Stage.introduction, app.scene.menu.stage);
    try backend.inject(.{
        .time_ns = backend.clock_ns,
        .payload = .{ .key_down = .{ .key = .tab, .repeat = true } },
    });
    _ = try app.update(&platform);
    try std.testing.expectEqual(game.front_end.Stage.introduction, app.scene.menu.stage);
    try backend.inject(.{
        .time_ns = backend.clock_ns,
        .payload = .{ .key_up = .{ .key = .tab } },
    });
    try backend.inject(.{
        .time_ns = backend.clock_ns,
        .payload = .{ .key_down = .{ .key = .tab } },
    });
    _ = try app.update(&platform);
    try std.testing.expectEqual(game.front_end.Stage.menu, app.scene.menu.stage);
}
