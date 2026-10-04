//! Incomplete floppy resources fail explicitly; menu preview remains independently usable.
const std = @import("std");
const game = @import("flashbackz");

test "floppy menu preview cannot silently skip missing introduction or enter CD gameplay" {
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
    try std.testing.expectError(error.MissingFloppyIntroduction, game.Game.init(allocator, source.assetSource(), null));
    var preview = try game.Game.initWithEntry(allocator, source.assetSource(), null, .menu_development);
    defer preview.deinit();
    const front = &preview.scene.menu;
    try front.event(.{ .time_ns = 0, .payload = .{ .key_down = .{ .key = .down } } });
    try front.event(.{ .time_ns = 1, .payload = .{ .key_down = .{ .key = .enter } } });
    try std.testing.expectEqual(game.front_end.View.skill, front.view);
    try front.event(.{ .time_ns = 2, .payload = .{ .key_down = .{ .key = .up } } });
    try front.event(.{ .time_ns = 3, .payload = .{ .key_down = .{ .key = .enter } } });
    try std.testing.expectEqual(game.settings.Difficulty.easy, front.difficulty);
    try std.testing.expectEqual(game.front_end.View.main, front.view);
    try std.testing.expectError(error.FloppyGameplayNotYetQualified, front.start(null));
}
