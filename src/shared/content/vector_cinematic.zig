//! Import vector cinematic resources into owned pictures and timed holds. Source commands
//! end here: the player receives immutable drawing lists, palettes and durations.
const std = @import("std");
const platform = @import("../platform.zig");
const film = @import("../vector_film.zig");
const shapes = @import("../render/indexed_shapes.zig");
const palette = @import("palette.zig");
const transforms = @import("cinematic_transform.zig");
const cinematic_text = @import("cinematic_text.zig");
const font_mod = @import("font.zig");
const Treatment = enum { placed, scaled, rotated };

pub const OwnedFilm = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    frames: []const film.Frame,
    font: ?font_mod.Font = null,

    pub fn view(self: *const OwnedFilm) film.View {
        return .{ .frames = self.frames, .font = self.font };
    }
    pub fn deinit(self: *OwnedFilm) void {
        self.arena.deinit();
        self.allocator.destroy(self.arena);
        self.* = undefined;
    }
};

const Reader = struct {
    bytes: []const u8,
    at: usize = 0,
    fn take(self: *Reader, count: usize) ![]const u8 {
        if (self.at > self.bytes.len or count > self.bytes.len - self.at) return error.TruncatedCinematic;
        const result = self.bytes[self.at..][0..count];
        self.at += count;
        return result;
    }
    fn byte(self: *Reader) !u8 {
        return (try self.take(1))[0];
    }
    fn word(self: *Reader) !u16 {
        return std.mem.readInt(u16, (try self.take(2))[0..2], .big);
    }
    fn signed(self: *Reader) !i16 {
        return @bitCast(try self.word());
    }
};
fn wordAt(bytes: []const u8, at: usize) !u16 {
    var reader: Reader = .{ .bytes = bytes, .at = at };
    return reader.word();
}

/// Lattice scaling is anchored on the shape's first vertex. Keeping that rounded anchor
/// separate from point displacement preserves integer ties without a legacy carry register.
const Scale = struct {
    factor: i16,
    pivot: shapes.Point,
    origin: ?shapes.Point = null,
    fn rounded(self: Scale, delta: i32) i32 {
        const product = (delta *% @as(i32, self.factor)) *% 128;
        return (product +% 32768) >> 16;
    }
    fn point(self: *Scale, input: shapes.Point) shapes.Point {
        const origin = self.origin orelse input;
        self.origin = origin;
        return .{
            .x = @truncate(@as(i32, self.pivot.x) - self.rounded(@as(i32, self.pivot.x) - origin.x) + self.rounded(@as(i32, input.x) - origin.x)),
            .y = @truncate(@as(i32, self.pivot.y) - self.rounded(@as(i32, self.pivot.y) - origin.y) + self.rounded(@as(i32, input.y) - origin.y)),
        };
    }
};

fn mapPoint(scale: *?Scale, rotation: ?transforms.Projection, point: shapes.Point) shapes.Point {
    const projected = if (rotation) |projection| projection.point(point, scale.*.?.pivot) else point;
    return if (scale.*) |*transform| transform.point(projected) else projected;
}

const Builder = struct {
    allocator: std.mem.Allocator,
    geometry: []const u8,
    source: ?platform.AssetSource = null,
    text_assets: ?cinematic_text.Text = null,
    captions: []const film.TextRun = &.{},
    caption_band: bool = false,
    frames: std.ArrayList(film.Frame) = .empty,
    working: std.ArrayList(film.Drawing) = .empty,
    saved_background: []const film.Drawing = &.{},
    visible: []const film.Drawing = &.{},
    colors: palette.Palette = @splat(.{ .r = 0, .g = 0, .b = 0 }),
    background_mode: u8 = 0,
    wait_ticks: u32 = 0,
    vertices: usize = 0,
    references: usize = 0,

    fn snapshot(self: *Builder, drawings: []const film.Drawing) ![]const film.Drawing {
        if (drawings.len > 1_000_000 - self.references) return error.CinematicTooLarge;
        self.references += drawings.len;
        return self.allocator.dupe(film.Drawing, drawings);
    }
    fn clear(self: *Builder) !void {
        self.working.clearRetainingCapacity();
        if (self.background_mode != 0) {
            self.captions = &.{};
            self.caption_band = false;
        }
        if (self.background_mode == 0) try self.working.appendSlice(self.allocator, self.saved_background);
    }
    fn present(self: *Builder, ticks: u32) !void {
        if (self.frames.items.len >= 10000) return error.CinematicTooLarge;
        const previous = &self.frames.items[self.frames.items.len - 1];
        previous.hold_ticks = try std.math.add(u32, previous.hold_ticks, try std.math.add(u32, self.wait_ticks, ticks));
        self.wait_ticks = 0;
        self.visible = try self.snapshot(self.working.items);
        try self.frames.append(self.allocator, .{ .drawings = self.visible, .colors = self.colors, .hold_ticks = 0, .captions = self.captions, .caption_band = self.caption_band });
    }
    fn textAssets(self: *Builder) !cinematic_text.Text {
        if (self.text_assets == null) {
            self.text_assets = try cinematic_text.load(self.allocator, self.source orelse return error.CinematicTextRequired);
            @memcpy(self.colors[0xe0..0xf0], &self.text_assets.?.colors);
        }
        return self.text_assets.?;
    }
    fn caption(self: *Builder, reference: u16) !void {
        self.caption_band = true;
        self.captions = if (reference == 0xffff) &.{} else try (try self.textAssets()).layout(self.allocator, reference, 8, 179, 0xef, true);
    }
    fn positionedText(self: *Builder, reference: u16, x: u8, y: u8) !void {
        const rows = try (try self.textAssets()).layout(self.allocator, reference & 0xfff, 8 + @as(i16, x) * 8, 50 + @as(i16, y) * 8, @intCast(0xd0 + (reference >> 12)), false);
        for (rows) |run| try self.working.append(self.allocator, .{ .geometry = .{ .text = run }, .ink = .{ .color = run.foreground } });
    }
    fn setPalette(self: *Builder, bank: u8, destination: u8) !void {
        if (destination > 1) return error.InvalidCinematicPalette;
        const at = @as(usize, try wordAt(self.geometry, 6)) + @as(usize, bank) * 32;
        const first: usize = if (destination == 1) 0xc0 else 0xd0;
        for (0..16) |i| {
            const color = try wordAt(self.geometry, at + i * 2);
            const low: u8 = if (color == 0) 0 else 3;
            const r: u8 = (@as(u8, @truncate(color >> 8)) & 15) * 4 | low;
            const g: u8 = (@as(u8, @truncate(color >> 4)) & 15) * 4 | low;
            const b: u8 = (@as(u8, @truncate(color)) & 15) * 4 | low;
            self.colors[first + i] = .{ .r = (r << 2) | (r >> 4), .g = (g << 2) | (g >> 4), .b = (b << 2) | (b >> 4) };
        }
    }
    fn drawShape(self: *Builder, command: *Reader, treatment: Treatment) !void {
        const reference = try command.word();
        if (reference & @as(u16, if (treatment == .rotated) 0x0800 else 0x7800) != 0) return error.UnsupportedCinematicShapeFlags;
        var placement: shapes.Point = .{ .x = 8, .y = 50 };
        if (reference & 0x8000 != 0) {
            placement.x +%= try command.signed();
            placement.y +%= try command.signed();
        }
        var scale: ?Scale = null;
        var rotation: ?transforms.Projection = null;
        if (treatment != .placed) {
            const factor: i16 = if (treatment == .scaled or reference & 0x4000 != 0) @bitCast((try command.word()) +% 512) else 512;
            const pivot: shapes.Point = .{ .x = try command.byte(), .y = try command.byte() };
            scale = .{ .factor = factor, .pivot = pivot };
            if (treatment == .rotated) rotation = try transforms.Projection.fromDegrees(
                try command.word(),
                if (reference & 0x2000 != 0) try command.word() else 180,
                if (reference & 0x1000 != 0) try command.word() else 90,
            );
        }
        const shape_table = try wordAt(self.geometry, 2);
        const shape_base = try wordAt(self.geometry, 14);
        const vertex_table = try wordAt(self.geometry, 10);
        const vertex_base = try wordAt(self.geometry, 18);
        var records: Reader = .{ .bytes = self.geometry, .at = @as(usize, shape_base) + try wordAt(self.geometry, @as(usize, shape_table) + @as(usize, reference & 0x7ff) * 2) };
        const count = try records.word();
        if (count > 1024) return error.CinematicTooLarge;
        for (0..count) |_| {
            const vertex_ref = try records.word();
            var offset: shapes.Point = .{ .x = 0, .y = 0 };
            if (vertex_ref & 0x8000 != 0) offset = .{ .x = try records.signed(), .y = try records.signed() };
            const color = try records.byte();
            if (color > 15) return error.InvalidCinematicInk;
            const ink = color + @as(u8, if (self.background_mode == 0) 0xd0 else 0xc0);
            var vertices: Reader = .{ .bytes = self.geometry, .at = @as(usize, vertex_base) + try wordAt(self.geometry, @as(usize, vertex_table) + @as(usize, vertex_ref & 0x3fff) * 2) };
            const kind = try vertices.byte();
            var point: shapes.Point = .{ .x = (try vertices.signed()) +% offset.x, .y = (try vertices.signed()) +% offset.y };
            if (self.vertices > 2_000_000 - 128) return error.CinematicTooLarge;
            var drawing: film.Drawing = undefined;
            if (kind & 128 != 0) {
                var rx = try vertices.signed();
                var ry = try vertices.signed();
                if (rx < 0 or ry < 0) return error.InvalidCinematicEllipse;
                if (rotation) |projection| point = projection.point(point, scale.?.pivot);
                if (scale) |*transform| {
                    const center = transform.point(point);
                    const top = transform.point(.{ .x = point.x, .y = point.y -% ry });
                    const left = transform.point(.{ .x = point.x -% rx, .y = point.y });
                    point = center;
                    rx = center.x -% left.x;
                    ry = center.y -% top.y;
                }
                if (rx < 0 or ry < 0) return error.InvalidCinematicEllipse;
                drawing.geometry = .{ .ellipse = .{ .center = .{ .x = point.x +% placement.x, .y = point.y +% placement.y }, .radius_x = @intCast(rx), .radius_y = @intCast(ry) } };
                self.vertices += 1;
            } else {
                if (kind >= 64) return error.UnsupportedCinematicPolygon;
                var points: [64]shapes.Point = undefined;
                var used: usize = 1;
                points[0] = mapPoint(&scale, rotation, point);
                for (0..kind) |i| {
                    const dx: i8 = @bitCast(try vertices.byte());
                    const dy: i8 = @bitCast(try vertices.byte());
                    point.x +%= dx;
                    point.y +%= dy;
                    if (dy == 0 and i + 1 < kind) {
                        if (vertices.at + 2 > vertices.bytes.len) return error.TruncatedCinematic;
                        if (vertices.bytes[vertices.at + 1] == 0) continue;
                    }
                    points[used] = mapPoint(&scale, rotation, point);
                    used += 1;
                }
                for (points[0..used]) |*vertex| {
                    vertex.x +%= placement.x;
                    vertex.y +%= placement.y;
                }
                drawing.geometry = .{ .polygon = try self.allocator.dupe(shapes.Point, points[0..used]) };
                self.vertices += used;
            }
            const tintable = drawing.geometry == .ellipse or drawing.geometry.polygon.len >= 3;
            drawing.ink = if (vertex_ref & 0x4000 != 0 and ink > 0xc7 and tintable) .{ .mask = ink & 0xf8 } else .{ .color = ink };
            try self.working.append(self.allocator, drawing);
        }
        if (self.background_mode != 0) self.saved_background = try self.snapshot(self.working.items);
    }
};

pub fn compile(allocator: std.mem.Allocator, commands: []const u8, polygons: []const u8, entry: u16) !OwnedFilm {
    return compileFrom(allocator, commands, polygons, entry, null);
}

fn compileFrom(allocator: std.mem.Allocator, commands: []const u8, polygons: []const u8, entry: u16, source: ?platform.AssetSource) !OwnedFilm {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    const content = arena.allocator();
    var header: Reader = .{ .bytes = commands };
    const entries = try header.word();
    if (entries > 1024 or entry >= @max(entries, 1)) return error.InvalidCinematicEntry;
    const start: usize = (@as(usize, entries) + 1) * 2;
    if (start > commands.len) return error.TruncatedCinematic;
    var reader: Reader = .{ .bytes = commands, .at = start + if (entry == 0) @as(usize, 0) else try wordAt(commands, 2 + @as(usize, entry) * 2) };
    var builder: Builder = .{ .allocator = content, .geometry = polygons, .source = source };
    try builder.frames.append(content, .{ .drawings = &.{}, .colors = builder.colors, .hold_ticks = 0 });
    var finished = false;
    for (0..100000) |_| {
        const encoded = try reader.byte();
        if (encoded & 128 != 0) {
            finished = true;
            break;
        }
        if (encoded & 3 != 0) return error.UnsupportedCinematicCommandFlags;
        switch (encoded >> 2) {
            0, 5 => {
                try builder.present(4);
                try builder.clear();
            },
            1 => {
                builder.background_mode = try reader.byte();
                if (builder.background_mode != 0) try builder.clear();
            },
            2 => builder.wait_ticks = try std.math.add(u32, builder.wait_ticks, @as(u32, try reader.byte()) * 4),
            3 => try builder.drawShape(&reader, .placed),
            4 => try builder.setPalette(try reader.byte(), try reader.byte()),
            6 => try builder.caption(try reader.word()),
            7 => {},
            13 => {
                const reference = try reader.word();
                if (reference != 0xffff) try builder.positionedText(reference, try reader.byte(), try reader.byte());
            },
            8 => _ = try reader.take(3),
            10 => try builder.drawShape(&reader, .scaled),
            12 => {
                builder.working.clearRetainingCapacity();
                try builder.working.appendSlice(content, builder.visible);
                try builder.present(9);
            },
            9, 14 => |kind| {
                if (kind == 9) {
                    try builder.present(4);
                    try builder.clear();
                }
                const mask = try reader.byte();
                if (mask == 255) continue;
                const destination = try reader.signed();
                if (mask != 0 or destination >= 0) return error.UnsupportedCinematicInteraction;
                finished = true;
                break;
            },
            11 => try builder.drawShape(&reader, .rotated),
            else => return error.UnsupportedCinematicCommand,
        }
    }
    if (!finished) return error.CinematicTooLarge;
    builder.frames.items[builder.frames.items.len - 1].hold_ticks = builder.wait_ticks;
    const frames = try builder.frames.toOwnedSlice(content);
    return .{ .allocator = allocator, .arena = arena, .frames = frames, .font = if (builder.text_assets) |assets| assets.font else null };
}

pub fn load(allocator: std.mem.Allocator, source: platform.AssetSource, name: []const u8, entry: u16) !OwnedFilm {
    var path: [64]u8 = undefined;
    var commands = try source.readAll(try std.fmt.bufPrint(&path, "DATA/{s}.CMD", .{name}), 65536);
    defer commands.deinit();
    var polygons = try source.readAll(try std.fmt.bufPrint(&path, "DATA/{s}.POL", .{name}), 65536);
    defer polygons.deinit();
    return compileFrom(allocator, commands.bytes, polygons.bytes, entry, source);
}

fn testGeometry() [66]u8 {
    var pol: [66]u8 = @splat(0);
    for ([_]usize{ 2, 6, 10, 14, 18 }, [_]u16{ 20, 22, 54, 56, 61 }) |offset, value| std.mem.writeInt(u16, pol[offset..][0..2], value, .big);
    std.mem.writeInt(u16, pol[24..26], 0x123, .big);
    std.mem.writeInt(u16, pol[56..58], 1, .big);
    pol[60] = 1;
    return pol;
}
const test_commands = [_]u8{
    0, 0,
    4,  1,  12,  0,  0, // static point, retained by the following dynamic frames
    4,  0,  16,  0,  1,
    16, 0,  0,   12, 128,
    0,  0,  1,   0,  0,
    0,  12, 128, 0,  0,
    2,  0,  0,   0,  255,
};

test "imported pictures retain backgrounds without retaining prior moving drawings" {
    const allocator = std.testing.allocator;
    const geometry = testGeometry();
    var content = try compile(allocator, &test_commands, &geometry, 0);
    defer content.deinit();
    try std.testing.expectEqual(@as(usize, 3), content.frames.len);
    const pixels = try allocator.alloc(u8, 256 * 224);
    defer allocator.free(pixels);
    const rgba = try allocator.alloc(u8, pixels.len * 4);
    defer allocator.free(rgba);
    try content.view().draw(1, pixels, rgba);
    try std.testing.expectEqualSlices(u8, &.{ 0xc1, 0xd1, 0xc0 }, pixels[50 * 256 + 8 ..][0..3]);
    try std.testing.expectEqualSlices(u8, &.{ 28, 44, 60, 255 }, rgba[(50 * 256 + 8) * 4 ..][0..4]);
    try content.view().draw(2, pixels, rgba);
    try std.testing.expectEqualSlices(u8, &.{ 0xc1, 0xc0, 0xd1 }, pixels[50 * 256 + 8 ..][0..3]);
    try std.testing.expectEqual(@as(u32, 4), content.frames[0].hold_ticks);
    try std.testing.expectEqual(@as(u32, 4), content.frames[1].hold_ticks);
    try std.testing.expectEqual(@as(u32, 0), content.frames[2].hold_ticks);
}

fn allocationExercise(allocator: std.mem.Allocator) !void {
    const geometry = testGeometry();
    var content = try compile(allocator, &test_commands, &geometry, 0);
    defer content.deinit();
}

test "malformed cinematic content and allocation failure release partially compiled frames" {
    const allocator = std.testing.allocator;
    const geometry = testGeometry();
    try std.testing.expectError(error.TruncatedCinematic, compile(allocator, &.{0}, &geometry, 0));
    try std.testing.expectError(error.InvalidCinematicEntry, compile(allocator, &test_commands, &geometry, 1));
    try std.testing.expectError(error.UnsupportedCinematicInteraction, compile(allocator, &.{ 0, 0, 56, 1, 0, 0, 255 }, &geometry, 0));
    try std.testing.expectError(error.TruncatedCinematic, compile(allocator, &test_commands, geometry[0..62], 0));
    try std.testing.checkAllAllocationFailures(allocator, allocationExercise, .{});
}
