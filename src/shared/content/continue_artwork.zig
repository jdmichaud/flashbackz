//! Freeze the Continue illustration through the shared cinematic importer and renderer.
//! The dialog owns its picture, glyphs and labels; no duplicate drawing decoder is needed.
const std = @import("std");
const platform = @import("../platform.zig");
const palette = @import("palette.zig");
const font_mod = @import("font.zig");
pub const Assets = struct {
    allocator: std.mem.Allocator,
    pixels: []u8,
    colors: palette.Palette,
    font: font_mod.Font,
    labels: []u8,
    title: []const u8,
    time: []const u8,
    retry: []const u8,
    abort: []const u8,
    score: []const u8,
    pub fn deinit(self: *Assets) void {
        self.allocator.free(self.pixels);
        self.font.deinit();
        self.allocator.free(self.labels);
        self.* = undefined;
    }
};
pub fn load(allocator: std.mem.Allocator, source: platform.AssetSource) !Assets {
    const interface = try @import("floppy_interface.zig").load(allocator, source);
    var film = try @import("vector_cinematic.zig").load(allocator, source, "SCORE", 0);
    defer film.deinit();
    var font_data = try source.readAll("DATA/FB_TXT.FNT", 16384);
    defer font_data.deinit();
    var font = try font_mod.decode(allocator, font_data.bytes);
    errdefer font.deinit();
    const pixels = try allocator.alloc(u8, 256 * 224);
    errdefer allocator.free(pixels);
    const rgba = try allocator.alloc(u8, pixels.len * 4);
    defer allocator.free(rgba);
    const frame = film.frames.len - 1;
    try film.view().draw(frame, pixels, rgba);
    var colors = film.frames[frame].colors;
    @memcpy(colors[0xe0..0xf0], &interface.text_colors);
    const labels = try allocator.dupe(u8, std.mem.asBytes(&interface.continue_labels));
    return .{ .allocator = allocator, .pixels = pixels, .colors = colors, .font = font, .labels = labels, .title = std.mem.sliceTo(labels[0..48], 0), .time = std.mem.sliceTo(labels[48..96], 0), .retry = std.mem.sliceTo(labels[96..144], 0), .abort = std.mem.sliceTo(labels[144..192], 0), .score = std.mem.sliceTo(labels[192..240], 0) };
}
