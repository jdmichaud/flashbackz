//! A PNG writer for 8-bit RGB images: one IDAT chunk, zlib-compressed by the standard library.
//! Each row takes the filter whose output has the smallest sum of magnitudes, the usual heuristic
//! (PNG specification, section 12.8).
const std = @import("std");

const signature = "\x89PNG\r\n\x1a\n";
const channels = 3;

/// Writes `rgb` (row-major, three bytes a pixel) as a PNG image to `out`.
pub fn write(
    allocator: std.mem.Allocator,
    out: *std.Io.Writer,
    width: u32,
    height: u32,
    rgb: []const u8,
) !void {
    std.debug.assert(rgb.len == @as(usize, width) * height * channels);
    try out.writeAll(signature);

    var header: [13]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], width, .big);
    std.mem.writeInt(u32, header[4..8], height, .big);
    // Bit depth 8, color type 2 (RGB), deflate, adaptive filtering, no interlace.
    header[8..13].* = .{ 8, 2, 0, 0, 0 };
    try chunk(out, "IHDR", &header);

    // The compressor needs room in its output from the start.
    var compressed: std.Io.Writer.Allocating = try .initCapacity(allocator, 64 * 1024);
    defer compressed.deinit();
    const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(window);
    var zlib = try std.compress.flate.Compress.init(&compressed.writer, window, .zlib, .default);

    const stride = @as(usize, width) * channels;
    const filtered = try allocator.alloc(u8, 5 * (1 + stride));
    defer allocator.free(filtered);
    const zero = try allocator.alloc(u8, stride);
    defer allocator.free(zero);
    @memset(zero, 0);
    for (0..height) |y| {
        const row = rgb[y * stride..][0..stride];
        const above = if (y == 0) zero else rgb[(y - 1) * stride..][0..stride];
        try zlib.writer.writeAll(bestFilter(filtered, row, above));
    }
    try zlib.finish();
    try chunk(out, "IDAT", compressed.written());
    try chunk(out, "IEND", "");
}

fn chunk(out: *std.Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    try out.writeInt(u32, @intCast(data.len), .big);
    try out.writeAll(kind);
    try out.writeAll(data);
    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(data);
    try out.writeInt(u32, crc.final(), .big);
}

/// Filters `row` the five ways into `scratch` and returns the one whose bytes, read as signed,
/// sum to the least magnitude, its filter type byte first.
fn bestFilter(scratch: []u8, row: []const u8, above: []const u8) []const u8 {
    const size = 1 + row.len;
    var best: usize = 0;
    var best_cost: u64 = std.math.maxInt(u64);
    for (0..5) |kind| {
        const out = scratch[kind * size..][0..size];
        out[0] = @intCast(kind);
        var cost: u64 = 0;
        for (row, above, 0..) |value, up, i| {
            const left: u8 = if (i >= channels) row[i - channels] else 0;
            const corner: u8 = if (i >= channels) above[i - channels] else 0;
            const predicted: u8 = switch (kind) {
                0 => 0,
                1 => left,
                2 => up,
                3 => @intCast((@as(u16, left) + up) / 2),
                else => paeth(left, up, corner),
            };
            const filtered = value -% predicted;
            out[1 + i] = filtered;
            cost += @abs(@as(i8, @bitCast(filtered)));
        }
        if (cost < best_cost) {
            best = kind;
            best_cost = cost;
        }
    }
    return scratch[best * size..][0..size];
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

test "a written image has its header, valid chunk checksums and its pixels back" {
    const allocator = std.testing.allocator;
    const width = 7;
    const height = 5;
    var rgb: [width * height * channels]u8 = undefined;
    for (&rgb, 0..) |*value, i| {
        value.* = @truncate(i * 37 + i / 21);
    }

    var encoded: std.Io.Writer.Allocating = .init(allocator);
    defer encoded.deinit();
    try write(allocator, &encoded.writer, width, height, &rgb);
    const bytes = encoded.written();
    try std.testing.expectEqualStrings(signature, bytes[0..8]);

    var idat: []const u8 = &.{};
    var at: usize = 8;
    var kinds: [3][4]u8 = undefined;
    var count: usize = 0;
    while (at < bytes.len) {
        const length = std.mem.readInt(u32, bytes[at..][0..4], .big);
        const kind = bytes[at + 4..][0..4];
        const data = bytes[at + 8..][0..length];
        var crc: std.hash.Crc32 = .init();
        crc.update(kind);
        crc.update(data);
        try std.testing.expectEqual(
            crc.final(),
            std.mem.readInt(u32, bytes[at + 8 + length..][0..4], .big),
        );
        if (std.mem.eql(u8, kind, "IHDR")) {
            try std.testing.expectEqual(@as(u32, width), std.mem.readInt(u32, data[0..4], .big));
            try std.testing.expectEqual(@as(u32, height), std.mem.readInt(u32, data[4..8], .big));
            try std.testing.expectEqualSlices(u8, &.{ 8, 2, 0, 0, 0 }, data[8..13]);
        }
        if (std.mem.eql(u8, kind, "IDAT")) {
            idat = data;
        }
        kinds[count] = kind.*;
        count += 1;
        at += 12 + length;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualStrings("IEND", &kinds[2]);

    var reader: std.Io.Reader = .fixed(idat);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var inflate: std.compress.flate.Decompress = .init(&reader, .zlib, &window);
    var raw: std.Io.Writer.Allocating = .init(allocator);
    defer raw.deinit();
    _ = try inflate.reader.streamRemaining(&raw.writer);
    const stride = width * channels;
    try std.testing.expectEqual(@as(usize, height * (1 + stride)), raw.written().len);

    // Undo the filters and compare.
    var decoded: [width * height * channels]u8 = undefined;
    for (0..height) |y| {
        const line = raw.written()[y * (1 + stride)..][0..1 + stride];
        for (0..stride) |i| {
            const left: u8 = if (i >= channels) decoded[y * stride + i - channels] else 0;
            const up: u8 = if (y > 0) decoded[(y - 1) * stride + i] else 0;
            const corner: u8 = if (y > 0 and i >= channels)
                decoded[(y - 1) * stride + i - channels]
            else
                0;
            const predicted: u8 = switch (line[0]) {
                0 => 0,
                1 => left,
                2 => up,
                3 => @intCast((@as(u16, left) + up) / 2),
                4 => paeth(left, up, corner),
                else => return error.BadFilter,
            };
            decoded[y * stride + i] = line[1 + i] +% predicted;
        }
    }
    try std.testing.expectEqualSlices(u8, &rgb, &decoded);
}
