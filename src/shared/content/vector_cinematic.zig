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
        if (self.at > self.bytes.len or
            count > self.bytes.len - self.at) {
            return error.TruncatedCinematic;
        }
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
    /// In units of 1/512: 512 keeps the size.
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
            .x = @truncate(
                @as(i32, self.pivot.x) -
                    self.rounded(@as(i32, self.pivot.x) - origin.x) +
                    self.rounded(@as(i32, input.x) - origin.x),
            ),
            .y = @truncate(
                @as(i32, self.pivot.y) -
                    self.rounded(@as(i32, self.pivot.y) - origin.y) +
                    self.rounded(@as(i32, input.y) - origin.y),
            ),
        };
    }
};

fn mapPoint(scale: *?Scale, rotation: ?transforms.Projection, point: shapes.Point) shapes.Point {
    const projected = if (rotation) |projection|
        projection.point(point, scale.*.?.pivot)
    else
        point;
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
    /// Presents of the held picture the waits since the last present make in replay mode.
    wait_presents: u32 = 0,
    /// A new background since the last present.
    new_background: bool = false,
    /// The two display pages, and which of them holds the caption's bottom row (see
    /// `film.Frame.caption_tail`).
    back_page: u1 = 0,
    page_tail: [2]bool = .{ true, true },
    vertices: usize = 0,
    references: usize = 0,

    fn snapshot(self: *Builder, drawings: []const film.Drawing) ![]const film.Drawing {
        if (drawings.len > 1_000_000 - self.references) return error.CinematicTooLarge;
        self.references += drawings.len;
        return self.allocator.dupe(film.Drawing, drawings);
    }
    /// Starts the next picture. In background mode 0 it starts from the saved background;
    /// in another mode it starts empty and removes the caption.
    fn clear(self: *Builder) !void {
        self.working.clearRetainingCapacity();
        if (self.background_mode != 0) {
            self.captions = &.{};
            self.caption_band = false;
        }
        if (self.background_mode == 0) {
            try self.working.appendSlice(self.allocator, self.saved_background);
        }
    }
    fn present(self: *Builder, ticks: u32, replay: film.ReplayPresent) !void {
        if (self.frames.items.len >= 10000) return error.CinematicTooLarge;
        const previous = &self.frames.items[self.frames.items.len - 1];
        previous.hold_ticks = try std.math.add(
            u32,
            previous.hold_ticks,
            try std.math.add(u32, self.wait_ticks, ticks),
        );
        previous.held_presents += self.wait_presents;
        self.wait_ticks = 0;
        self.wait_presents = 0;
        // A hold copies the shown page onto the one it presents.
        if (replay == .hold) {
            self.page_tail[self.back_page] = self.page_tail[self.back_page ^ 1];
        }
        const caption_tail = self.page_tail[self.back_page];
        self.back_page ^= 1;
        self.visible = try self.snapshot(self.working.items);
        try self.frames.append(self.allocator, .{
            .drawings = self.visible,
            .colors = self.colors,
            .hold_ticks = 0,
            .captions = self.captions,
            .caption_band = self.caption_band,
            .present_ticks = @intCast(ticks),
            .replay_present = replay,
            .ends_hold = self.new_background,
            .caption_tail = caption_tail,
        });
        self.new_background = false;
    }
    fn textAssets(self: *Builder) !cinematic_text.Text {
        if (self.text_assets == null) {
            self.text_assets = try cinematic_text.load(
                self.allocator,
                self.source orelse return error.CinematicTextRequired,
            );
            @memcpy(self.colors[0xe0..0xf0], &self.text_assets.?.colors);
        }
        return self.text_assets.?;
    }
    fn caption(self: *Builder, reference: u16) !void {
        self.caption_band = true;
        // The band is cleared on every page; the text goes onto the back page (and the saved
        // background, from which the other page gets all of it but its bottom row).
        self.page_tail = .{ false, false };
        self.page_tail[self.back_page] = true;
        self.captions = if (reference == 0xffff) &.{} else try (try self.textAssets()).layout(
            self.allocator,
            reference,
            8,
            179,
            0xef,
            true,
        );
    }
    fn positionedText(self: *Builder, reference: u16, x: u8, y: u8) !void {
        const rows = try (try self.textAssets()).layout(
            self.allocator,
            reference & 0xfff,
            8 + @as(i16, x) * 8,
            50 + @as(i16, y) * 8,
            @intCast(0xd0 + (reference >> 12)),
            false,
        );
        for (rows) |run| {
            try self.working.append(self.allocator, .{
                .geometry = .{ .text = run },
                .ink = .{ .color = run.foreground },
            });
        }
    }
    /// Sets 16 film colors from POL palette `bank`: at 0xd0 for destination 0, at 0xc0 for 1.
    /// A color is a big-endian 0RGB word, with the brightness rule of
    /// `palette.decodeLevelBank`.
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
            self.colors[first + i] = .{
                .r = (r << 2) | (r >> 4),
                .g = (g << 2) | (g >> 4),
                .b = (b << 2) | (b >> 4),
            };
        }
    }
    /// Reads a shape command and adds the shape's primitives to the picture. The reference
    /// word:
    /// - bits 0-10: the shape number; bit 11: must be 0;
    /// - bit 12 (rotated): a third angle word follows, else the angle is 90;
    /// - bit 13 (rotated): a second angle word follows, else the angle is 180;
    /// - bit 14 (rotated): a scale word follows, else the scale is 512;
    /// - bit 15: signed x and y words follow; they move the shape from (8, 50).
    /// Bits 11-14 must be 0 in a placed or scaled shape. Then a scaled or rotated shape has
    /// its scale word (always for a scaled one), the pivot x and y bytes and, if rotated, the
    /// first angle word. The scale word holds the factor minus 512.
    fn drawShape(self: *Builder, command: *Reader, treatment: Treatment) !void {
        const reference = try command.word();
        if (reference & @as(u16, if (treatment == .rotated) 0x0800 else 0x7800) != 0) {
            return error.UnsupportedCinematicShapeFlags;
        }
        var placement: shapes.Point = .{ .x = 8, .y = 50 };
        if (reference & 0x8000 != 0) {
            placement.x +%= try command.signed();
            placement.y +%= try command.signed();
        }
        var scale: ?Scale = null;
        var rotation: ?transforms.Projection = null;
        if (treatment != .placed) {
            const factor: i16 = if (treatment == .scaled or
                reference & 0x4000 != 0)
                @bitCast((try command.word()) +% 512)
            else
                512;
            const pivot: shapes.Point = .{ .x = try command.byte(), .y = try command.byte() };
            scale = .{ .factor = factor, .pivot = pivot };
            // The angles are in degrees, and the projection uses Q8 sines (256 is 1.0). A
            // first angle of 0 with the default angles 180 and 90 gives the identity.
            if (treatment == .rotated) {
                rotation = try transforms.Projection.fromDegrees(
                    try command.word(),
                    if (reference & 0x2000 != 0) try command.word() else 180,
                    if (reference & 0x1000 != 0) try command.word() else 90,
                );
            }
        }
        // The POL header, in big-endian words:
        // - at 2: the shape table, a word offset for each shape from the shape base;
        // - at 6: the palettes (`setPalette`);
        // - at 10: the vertex table, a word offset for each vertex record from the vertex base;
        // - at 14: the shape base; at 18: the vertex base.
        // A shape is a big-endian u16 count, then the primitives. A primitive:
        // 1. a word: bits 0-13 the vertex record, bit 14 a see-through ink, bit 15 an offset;
        // 2. with bit 15, the signed x and y words of the offset;
        // 3. a color byte (0-15).
        const shape_table = try wordAt(self.geometry, 2);
        const shape_base = try wordAt(self.geometry, 14);
        const vertex_table = try wordAt(self.geometry, 10);
        const vertex_base = try wordAt(self.geometry, 18);
        var records: Reader = .{
            .bytes = self.geometry,
            .at = @as(usize, shape_base) +
                try wordAt(
                    self.geometry,
                    @as(usize, shape_table) + @as(usize, reference & 0x7ff) * 2,
                ),
        };
        const count = try records.word();
        if (count > 1024) return error.CinematicTooLarge;
        for (0..count) |_| {
            const vertex_ref = try records.word();
            var offset: shapes.Point = .{ .x = 0, .y = 0 };
            if (vertex_ref & 0x8000 != 0) {
                offset = .{ .x = try records.signed(), .y = try records.signed() };
            }
            const color = try records.byte();
            if (color > 15) return error.InvalidCinematicInk;
            // The background (a nonzero mode) uses the colors at 0xc0, the rest those at 0xd0.
            const ink = color + @as(u8, if (self.background_mode == 0) 0xd0 else 0xc0);
            var vertices: Reader = .{
                .bytes = self.geometry,
                .at = @as(usize, vertex_base) +
                    try wordAt(
                        self.geometry,
                        @as(usize, vertex_table) + @as(usize, vertex_ref & 0x3fff) * 2,
                    ),
            };
            // A vertex record: a kind byte, then the signed x and y words of the first point.
            // With kind bit 7, it is an ellipse, and the signed x and y radii follow. Else the
            // kind (0-63) counts the next points, each a signed dx and dy byte.
            const kind = try vertices.byte();
            var point: shapes.Point = .{
                .x = (try vertices.signed()) +% offset.x,
                .y = (try vertices.signed()) +% offset.y,
            };
            if (self.vertices > 2_000_000 - 128) return error.CinematicTooLarge;
            var drawing: film.Drawing = undefined;
            if (kind & 128 != 0) {
                var rx = try vertices.signed();
                var ry = try vertices.signed();
                if (rx < 0 or ry < 0) return error.InvalidCinematicEllipse;
                // In a rotated shape an ellipse's centre moves only vertically: it takes the
                // rotated point's row and keeps its own column (the original's shapes,
                // flashback-re engine-ending-zoom 3.5).
                if (rotation) |projection| {
                    point.y = projection.point(point, scale.?.pivot).y;
                }
                if (scale) |*transform| {
                    const center = transform.point(point);
                    const top = transform.point(.{ .x = point.x, .y = point.y -% ry });
                    const left = transform.point(.{ .x = point.x -% rx, .y = point.y });
                    point = center;
                    rx = center.x -% left.x;
                    ry = center.y -% top.y;
                }
                if (rx < 0 or ry < 0) return error.InvalidCinematicEllipse;
                drawing.geometry = .{
                    .ellipse = .{
                        .center = .{ .x = point.x +% placement.x, .y = point.y +% placement.y },
                        .radius_x = @intCast(rx),
                        .radius_y = @intCast(ry),
                    },
                };
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
                    // A horizontal step that another horizontal step follows adds no point.
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
                drawing.geometry = .{
                    .polygon = try self.allocator.dupe(shapes.Point, points[0..used]),
                };
                self.vertices += used;
            }
            // A see-through shape brightens what is under it: it sets bit 3 of each pixel.
            const tintable = drawing.geometry == .ellipse or drawing.geometry.polygon.len >= 3;
            drawing.ink = if (vertex_ref & 0x4000 != 0 and
                ink > 0xc7 and
                tintable)
                .{ .mask = 0x08 }
            else
                .{ .color = ink };
            try self.working.append(self.allocator, drawing);
        }
        if (self.background_mode != 0) {
            self.saved_background = try self.snapshot(self.working.items);
        }
    }
};

pub fn compile(
    allocator: std.mem.Allocator,
    commands: []const u8,
    polygons: []const u8,
    entry: u16,
) !OwnedFilm {
    return compileFrom(allocator, commands, polygons, entry, null);
}

/// The CMD file starts with a big-endian u16 entry count, then a big-endian u16 offset for each
/// entry; entry 0 starts at offset 0. The offsets, and the jump targets, count from the end of
/// this table.
fn compileFrom(
    allocator: std.mem.Allocator,
    commands: []const u8,
    polygons: []const u8,
    entry: u16,
    source: ?platform.AssetSource,
) !OwnedFilm {
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
    var reader: Reader = .{
        .bytes = commands,
        .at = start +
            if (entry == 0) @as(usize, 0) else try wordAt(commands, 2 + @as(usize, entry) * 2),
    };
    var builder: Builder = .{ .allocator = content, .geometry = polygons, .source = source };
    try builder.frames.append(content, .{
        .drawings = &.{},
        .colors = builder.colors,
        .hold_ticks = 0,
        .presented = false,
    });
    // At each command reached: the frame its next present adds, and the wait due before it.
    const Reached = struct {
        frame: usize,
        wait_ticks: u32,
    };
    var reached: std.AutoHashMap(usize, Reached) = .init(allocator);
    defer reached.deinit();
    var finished = false;
    for (0..100000) |_| {
        const command_offset = reader.at;
        try reached.put(command_offset, .{
            .frame = builder.frames.items.len,
            .wait_ticks = builder.wait_ticks,
        });
        // A command byte: bit 7 ends the film, bits 2-6 are the opcode, bits 0-1 must be 0.
        // The opcodes and their operands:
        // - 0, 5: present the picture after 4 ticks, then start the next one (`clear`);
        // - 1 (a byte): set the background mode; a nonzero mode starts a new background;
        // - 2 (a byte n): wait n x 4 ticks;
        // - 3, 10, 11: draw a shape, placed, scaled or rotated (`drawShape`);
        // - 4 (a bank byte, a destination byte): set 16 colors (`setPalette`);
        // - 6 (a word): show the caption band, with this text unless the word is 0xffff;
        // - 7: nothing; 8 (3 bytes): the bytes are not used;
        // - 9: present the page after 4 ticks, start the next picture, then a page loop;
        // - 12: present the shown picture again after 9 ticks (a hold);
        // - 13 (a word, then x and y bytes): place a text; 0xffff has no x and y bytes;
        // - 14: a page loop.
        const encoded = try reader.byte();
        if (encoded & 128 != 0) {
            finished = true;
            break;
        }
        if (encoded & 3 != 0) return error.UnsupportedCinematicCommandFlags;
        switch (encoded >> 2) {
            0, 5 => {
                try builder.present(4, .picture);
                try builder.clear();
            },
            1 => {
                builder.background_mode = try reader.byte();
                if (builder.background_mode != 0) {
                    try builder.clear();
                    builder.new_background = true;
                }
            },
            2 => {
                const count = try reader.byte();
                builder.wait_ticks = try std.math.add(u32, builder.wait_ticks, @as(u32, count) * 4);
                builder.wait_presents += 2 * @as(u32, count) + 1;
            },
            3 => try builder.drawShape(&reader, .placed),
            4 => try builder.setPalette(try reader.byte(), try reader.byte()),
            6 => try builder.caption(try reader.word()),
            7 => {},
            13 => {
                // Bits 0-11 select the text, and bits 12-15 give the ink, plus 0xd0. The x and
                // y bytes count 8-pixel cells from (8, 50).
                const reference = try reader.word();
                if (reference != 0xffff) {
                    try builder.positionedText(reference, try reader.byte(), try reader.byte());
                }
            },
            8 => _ = try reader.take(3),
            10 => try builder.drawShape(&reader, .scaled),
            12 => {
                builder.working.clearRetainingCapacity();
                try builder.working.appendSlice(content, builder.visible);
                try builder.present(9, .hold);
            },
            9, 14 => |kind| {
                if (kind == 9) {
                    try builder.present(4, .page);
                    try builder.clear();
                }
                // A page loop:
                // 1. a mask byte; 255 means no loop and no more operands;
                // 2. a signed word: the target after a confirmation, negative for the end;
                //    mask 0 with a negative target ends the film at once;
                // 3. else mask 128, a 0 byte, a signed word (the target without a
                //    confirmation) and a 255 byte.
                const mask = try reader.byte();
                if (mask == 255) continue;
                const destination = try reader.signed();
                if (mask == 0 and destination < 0) {
                    finished = true;
                    break;
                }
                // The supplied page loops repeat the same picture while a key is held,
                // then await a new confirmation. Resolve their control flow at import;
                // playback receives pictures and timed confirmation loops.
                if (mask != 128 or
                    try reader.byte() != 0) {
                    return error.UnsupportedCinematicInteraction;
                }
                const fallback = try reader.signed();
                if (try reader.byte() != 255 or
                    fallback < 0) {
                    return error.UnsupportedCinematicInteraction;
                }
                const idle_target = start + @as(usize, @intCast(fallback));
                if (destination >= 0 and
                    start + @as(usize, @intCast(destination)) <= command_offset and
                    idle_target > command_offset) {
                    // A release loop: the next page waits for a confirmation.
                    reader.at = idle_target;
                } else if (destination < 0 and idle_target > command_offset) {
                    // A confirmation ends the film here; without one, it goes on.
                    builder.frames.items[builder.frames.items.len - 1].confirm_ends = true;
                    reader.at = idle_target;
                } else if (idle_target <= command_offset and
                    (destination < 0 or
                        start + @as(usize, @intCast(destination)) > command_offset)) {
                    const target = reached.get(idle_target) orelse
                        return error.UnsupportedCinematicInteraction;
                    const frames = builder.frames.items;
                    const last = &frames[frames.len - 1];
                    // Looping back costs the waits left after this picture, then those from the
                    // loop's target to the present of its first picture, and that present's own.
                    // A branch-only self-loop waits on the picture already presented.
                    const back = if (target.frame < frames.len)
                        try std.math.add(
                            u32,
                            builder.wait_ticks,
                            frames[target.frame - 1].hold_ticks,
                        )
                    else
                        builder.wait_ticks;
                    last.loop_ticks = std.math.sub(u32, back, target.wait_ticks) catch
                        return error.UnsupportedCinematicInteraction;
                    last.input_loop_start = @min(target.frame, frames.len - 1);
                    if (destination < 0) {
                        finished = true;
                        break;
                    }
                    reader.at = start + @as(usize, @intCast(destination));
                } else return error.UnsupportedCinematicInteraction;
            },
            11 => try builder.drawShape(&reader, .rotated),
            else => return error.UnsupportedCinematicCommand,
        }
    }
    if (!finished) return error.CinematicTooLarge;
    builder.frames.items[builder.frames.items.len - 1].hold_ticks = builder.wait_ticks;
    builder.frames.items[builder.frames.items.len - 1].held_presents += builder.wait_presents;
    const frames = try builder.frames.toOwnedSlice(content);
    return .{
        .allocator = allocator,
        .arena = arena,
        .frames = frames,
        .font = if (builder.text_assets) |assets| assets.font else null,
    };
}

pub fn load(
    allocator: std.mem.Allocator,
    source: platform.AssetSource,
    name: []const u8,
    entry: u16,
) !OwnedFilm {
    var path: [64]u8 = undefined;
    var commands = try source.readAll(
        try std.fmt.bufPrint(&path, "DATA/{s}.CMD", .{ name }),
        65536,
    );
    defer commands.deinit();
    var polygons = try source.readAll(
        try std.fmt.bufPrint(&path, "DATA/{s}.POL", .{ name }),
        65536,
    );
    defer polygons.deinit();
    return compileFrom(allocator, commands.bytes, polygons.bytes, entry, source);
}

fn testGeometry() [66]u8 {
    var pol: [66]u8 = @splat(0);
    for ([_]usize{ 2, 6, 10, 14, 18 }, [_]u16{ 20, 22, 54, 56, 61 }) |offset, value| {
        std.mem.writeInt(u16, pol[offset..][0..2], value, .big);
    }
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
    try std.testing.expectEqualSlices(u8, &.{ 0xc1, 0xd1, 0xc0 }, pixels[50 * 256 + 8..][0..3]);
    try std.testing.expectEqualSlices(u8, &.{ 28, 44, 60, 255 }, rgba[(50 * 256 + 8) * 4..][0..4]);
    try content.view().draw(2, pixels, rgba);
    try std.testing.expectEqualSlices(u8, &.{ 0xc1, 0xc0, 0xd1 }, pixels[50 * 256 + 8..][0..3]);
    try std.testing.expectEqual(@as(u32, 4), content.frames[0].hold_ticks);
    try std.testing.expectEqual(@as(u32, 4), content.frames[1].hold_ticks);
    try std.testing.expectEqual(@as(u32, 0), content.frames[2].hold_ticks);
}

test "page loops: a confirmation may end the film between pictures, a loop back costs its waits and presents" {
    const allocator = std.testing.allocator;
    const geometry = testGeometry();
    // The city's map terminals (MAP entries 0 to 3): the marker on, then two checks that end the
    // film on a confirmation and else go on; the marker off, then the same, the last check looping
    // back. Offsets count from the commands' start, after the entry table.
    const blink = [_]u8{
        0, 0, // no entry table
        0, // 0: present
        36, 128, 0xff, 0xfe, 0, 0, 9, 255, // 1: present; confirmed, the end, else on to 9
        56, 128, 0xff, 0xfe, 0, 0, 17, 255, // 9: confirmed, the end, else on to 17
        36, 128, 0xff, 0xfe, 0, 0, 25, 255, // 17: present; confirmed, the end, else on to 25
        56, 128, 0xff, 0xfe, 0, 0, 1, 255, // 25: confirmed, the end, else back to 1
    };
    var map = try compile(allocator, &blink, &geometry, 0);
    defer map.deinit();
    const marker = map.frames[map.frames.len - 2];
    const dark = map.frames[map.frames.len - 1];
    try std.testing.expect(marker.confirm_ends and marker.input_loop_start == null);
    try std.testing.expect(dark.confirm_ends);
    try std.testing.expectEqual(@as(?usize, map.frames.len - 2), dark.input_loop_start);
    // Each picture shows for one present: the dark one until the loop presents the marker again.
    try std.testing.expectEqual(@as(u32, 4), marker.hold_ticks);
    try std.testing.expectEqual(@as(u32, 4), dark.loop_ticks);

    // A loop back through a hold (the city's log, LOG entry 0), then a page that waits on itself
    // for a confirmation, which ends the film.
    const log = [_]u8{
        0, 0,
        0, // 0: present
        8, 1, // 1: hold for 4 ticks
        0, // 3: present
        56, 128, 0, 12, 0, 0, 1, 255, // 4: confirmed, on to 12, else back to the hold
        0, // 12: present
        56, 128, 0xff, 0xfe, 0, 0, 13, 255, // 13: confirmed, the end, else wait here
    };
    var page = try compile(allocator, &log, &geometry, 0);
    defer page.deinit();
    const looping = page.frames[page.frames.len - 2];
    try std.testing.expectEqual(@as(?usize, page.frames.len - 2), looping.input_loop_start);
    try std.testing.expectEqual(@as(u32, 8), looping.loop_ticks);
    try std.testing.expectEqual(@as(u32, 4), looping.hold_ticks);
    const waiting = page.frames[page.frames.len - 1];
    try std.testing.expectEqual(@as(?usize, page.frames.len - 1), waiting.input_loop_start);
    try std.testing.expectEqual(@as(u32, 0), waiting.loop_ticks);
    for (page.frames) |frame| {
        try std.testing.expect(!frame.confirm_ends);
    }
}

fn allocationExercise(allocator: std.mem.Allocator) !void {
    const geometry = testGeometry();
    var content = try compile(allocator, &test_commands, &geometry, 0);
    defer content.deinit();
}

test "malformed cinematic content and allocation failure release partially compiled frames" {
    const allocator = std.testing.allocator;
    const geometry = testGeometry();
    try std.testing.expectError(
        error.TruncatedCinematic,
        compile(allocator, &.{ 0 }, &geometry, 0),
    );
    try std.testing.expectError(
        error.InvalidCinematicEntry,
        compile(allocator, &test_commands, &geometry, 1),
    );
    try std.testing.expectError(
        error.UnsupportedCinematicInteraction,
        compile(allocator, &.{ 0, 0, 56, 1, 0, 0, 255 }, &geometry, 0),
    );
    try std.testing.expectError(
        error.TruncatedCinematic,
        compile(allocator, &test_commands, geometry[0..62], 0),
    );
    try std.testing.checkAllAllocationFailures(allocator, allocationExercise, .{});
}
