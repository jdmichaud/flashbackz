//! Read-only compatibility import of the first menu's files into owned modern artwork.
const std = @import("std");
const platform = @import("../platform.zig");
const bitmap = @import("bitmap.zig");
const palette = @import("palette.zig");
const font_mod = @import("font.zig");
const menu = @import("../scenes/menu.zig");
const memory = @import("../memory.zig");

pub const Assets = struct {
    background: bitmap.IndexedImage,
    colors: palette.Palette,
    font: font_mod.Font,

    pub fn deinit(self: *Assets) void {
        self.font.deinit();
        self.background.deinit();
        self.* = undefined;
    }

    pub fn artwork(self: *const Assets) menu.Artwork {
        return .{
            .background = &self.background,
            .colors = &self.colors,
            .font = &self.font,
            .labels = .{ "START", "LOAD", "SKILL", "PASSWORD", "INFO", "DEMO", "QUIT" },
        };
    }
};

fn read(
    source: platform.AssetSource,
    path: []const u8,
    maximum: usize,
) platform.AssetError!platform.OwnedBytes {
    return source.readAll(path, maximum) catch |err| switch (err) {
        error.NotFound => source.readAll(path[5..], maximum),
        else => err,
    };
}

/// No menu file means this is a synthetic platform-smoke source. Once the first file exists,
/// missing or invalid required files are errors rather than substituted artwork.
pub fn load(allocator: std.mem.Allocator, source: platform.AssetSource) !?Assets {
    var image_file = read(source, "DATA/MENU1.MAP", 57344) catch |err| switch (err) {
        error.NotFound => return null,
        else => return err,
    };
    defer image_file.deinit();
    var palette_file = try read(source, "DATA/MENU1.PAL", 768);
    defer palette_file.deinit();
    var font_file = try read(source, "DATA/FB_TXT.FNT", 16384);
    defer font_file.deinit();
    var background = try bitmap.decodePlanar(allocator, image_file.bytes, 256, 224);
    errdefer background.deinit();
    const colors = try palette.decodeRgb8(palette_file.bytes);
    const font = try font_mod.decode(allocator, font_file.bytes);
    return .{ .background = background, .colors = colors, .font = font };
}

pub fn loadNamed(
    allocator: std.mem.Allocator,
    source: platform.AssetSource,
    name: []const u8,
) !Assets {
    var path: [64]u8 = undefined;
    var image_file = try read(source, try std.fmt.bufPrint(&path, "DATA/{s}.MAP", .{name}), 57344);
    defer image_file.deinit();
    var palette_file = try read(source, try std.fmt.bufPrint(&path, "DATA/{s}.PAL", .{name}), 768);
    defer palette_file.deinit();
    var font_file = try read(source, "DATA/FB_TXT.FNT", 16384);
    defer font_file.deinit();
    var background = try bitmap.decodePlanar(allocator, image_file.bytes, 256, 224);
    errdefer background.deinit();
    const colors = try palette.decodeRgb8(palette_file.bytes);
    return .{
        .background = background,
        .colors = colors,
        .font = try font_mod.decode(allocator, font_file.bytes),
    };
}

test "missing menu is distinguishable from incomplete supplied content" {
    var source = memory.MemoryAssetSource.init(std.testing.allocator);
    defer source.deinit();
    try std.testing.expect((try load(std.testing.allocator, source.assetSource())) == null);
    const pixels: [57344]u8 = @splat(0);
    try source.add("DATA/MENU1.MAP", &pixels);
    try std.testing.expectError(error.NotFound, load(std.testing.allocator, source.assetSource()));
}
