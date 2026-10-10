//! The poster's design: a row per level on black, its name in the game font right-aligned
//! against a gutter, its map to the right in its own light, the map's joins tagged with letters.
const std = @import("std");
const flashbackz = @import("flashbackz");
const map_mod = @import("map.zig");
const pack_mod = @import("pack.zig");
const draw = @import("draw.zig");
const Font = flashbackz.content.font.Font;

pub const room_width = 256;
pub const room_height = 224;
/// Rooms stacked by their links overlap by eight rows: the room below repeats the bottom of
/// the room above (the collision grid's floors are 216 pixels apart).
pub const room_pitch = 216;

const margin = 384;
const label_width = 1440;
const label_gap = 256;
const row_gap = 320;
const piece_gap = 128;
const map_limit = 14 * room_width;
const name_scale = 14;
const number_scale = 6;
const note_scale = 4;
const glow_strength = 1.1;

const name_color: draw.Rgb = .{ 238, 238, 246 };
const note_color: draw.Rgb = .{ 150, 150, 162 };
const note_shadow: draw.Rgb = .{ 28, 28, 32 };

pub const Level = struct {
    name: []const u8,
    /// The accent's hue, in degrees.
    hue: f32,
    /// The drawn rooms' pixels, RGB, by room number.
    rooms: [map_mod.room_count]?[]const u8,
    map: map_mod.Map,
    joins: []const map_mod.Join,
};

/// A level's map drawn as one image, and where its joins' tags go on it.
const Block = struct {
    image: draw.Image,
    tags: []Tag,
};
const Tag = struct { letter: u8, x: i32, y: i32 };

pub fn render(allocator: std.mem.Allocator, font: *const Font, levels: []const Level) !draw.Canvas {
    const blocks = try allocator.alloc(Block, levels.len);
    var built: usize = 0;
    defer {
        for (blocks[0..built]) |*block| {
            block.image.deinit(allocator);
            allocator.free(block.tags);
        }
        allocator.free(blocks);
    }
    var map_width: u32 = 0;
    var height: u32 = 2 * margin + row_gap * @as(u32, @intCast(levels.len - 1));
    for (levels, blocks) |*level, *block| {
        block.* = try buildBlock(allocator, level);
        built += 1;
        map_width = @max(map_width, block.image.width);
        height += block.image.height;
    }

    var canvas = try draw.Canvas.init(allocator, margin + label_width + label_gap + map_width + margin, height);
    errdefer canvas.deinit(allocator);
    var y: i32 = margin;
    for (levels, blocks, 1..) |*level, *block, number| {
        const accent = draw.hue(level.hue, 0.58, 0.96);
        const x: i32 = margin + label_width + label_gap;
        try canvas.glow(allocator, &block.image, x, y, glow_strength);
        canvas.draw(&block.image, x, y);
        for (block.tags) |t| canvas.tag(font, t.letter, x + t.x, y + t.y, accent);
        drawLabel(&canvas, font, level, number, @intCast(block.image.height), y, accent);
        y += @as(i32, @intCast(block.image.height)) + row_gap;
    }
    return canvas;
}

/// The label, centered on the row and right-aligned against the gutter: the level's number,
/// its name (a line a word when it is too long), a rule in the accent, the count of rooms.
fn drawLabel(canvas: *draw.Canvas, font: *const Font, level: *const Level, number: usize, row_height: i32, top: i32, accent: draw.Rgb) void {
    var lines_buffer: [4][]const u8 = undefined;
    var lines: []const []const u8 = lines_buffer[0..1];
    lines_buffer[0] = level.name;
    if (draw.textWidth(level.name, name_scale) > label_width) {
        var words = std.mem.tokenizeScalar(u8, level.name, ' ');
        var count: usize = 0;
        while (words.next()) |word| : (count += 1) lines_buffer[count] = word;
        lines = lines_buffer[0..count];
    }
    const line_count: i32 = @intCast(lines.len);
    const name_height = line_count * 8 * name_scale + (line_count - 1) * 4 * name_scale;
    const rule_height = 8;
    const height = 8 * number_scale + 48 + name_height + 64 + rule_height + 56 + 8 * note_scale;
    const right = margin + label_width;
    var y = top + @divTrunc(row_height - height, 2);

    var text_buffer: [32]u8 = undefined;
    const heading = std.fmt.bufPrint(&text_buffer, "LEVEL {d}", .{number}) catch unreachable;
    canvas.text(font, heading, right - draw.textWidth(heading, number_scale), y, number_scale, accent, draw.darker(accent, 0.3));
    y += 8 * number_scale + 48;
    for (lines) |line| {
        canvas.text(font, line, right - draw.textWidth(line, name_scale), y, name_scale, name_color, draw.darker(accent, 0.32));
        y += 12 * name_scale;
    }
    y += 64 - 4 * name_scale;
    const rule_width = 16 * name_scale;
    canvas.fill(right - rule_width, y, rule_width, rule_height, accent);
    y += rule_height + 56;
    var rooms: usize = 0;
    for (level.map.cells) |cell| rooms += @intFromBool(cell != null);
    const note = std.fmt.bufPrint(&text_buffer, "{d} ROOMS", .{rooms}) catch unreachable;
    canvas.text(font, note, right - draw.textWidth(note, note_scale), y, note_scale, note_color, note_shadow);
}

fn buildBlock(allocator: std.mem.Allocator, level: *const Level) !Block {
    const map = &level.map;
    const piece_count = map.piece_count;
    // Each piece's room rectangles, top to bottom so lower rooms cover the rows they repeat.
    var rects: [map_mod.room_count]pack_mod.Rect = undefined;
    var order: [map_mod.room_count]u8 = undefined;
    var starts: [map_mod.room_count + 1]usize = undefined;
    var pieces: [map_mod.room_count]pack_mod.Piece = undefined;
    var count: usize = 0;
    for (0..piece_count) |p| {
        starts[p] = count;
        for (map.cells, 0..) |cell, room| {
            const c = cell orelse continue;
            if (c.piece != p) continue;
            order[count] = @intCast(room);
            count += 1;
        }
        std.sort.insertion(u8, order[starts[p]..count], map, struct {
            fn above(m: *const map_mod.Map, a: u8, b: u8) bool {
                const ca = m.cells[a].?;
                const cb = m.cells[b].?;
                return ca.y < cb.y or (ca.y == cb.y and ca.x < cb.x);
            }
        }.above);
        for (order[starts[p]..count], rects[starts[p]..count]) |room, *rect| {
            const c = map.cells[room].?;
            rect.* = .{ .x = c.x * room_width, .y = c.y * room_pitch, .w = room_width, .h = room_height };
        }
        const size = map.sizes[p];
        pieces[p] = .{
            .rooms = rects[starts[p]..count],
            .size = .{ .w = size.w * room_width, .h = (size.h - 1) * room_pitch + room_height },
        };
    }
    starts[piece_count] = count;

    var origins: [map_mod.room_count]pack_mod.Point = undefined;
    const size = pack_mod.pack(pieces[0..piece_count], map_limit, piece_gap, origins[0..piece_count]);
    var image = try draw.Image.init(allocator, @intCast(size.w), @intCast(size.h));
    errdefer image.deinit(allocator);
    for (0..piece_count) |p| {
        for (order[starts[p]..starts[p + 1]], rects[starts[p]..starts[p + 1]]) |room, rect| {
            const pixels = level.rooms[room] orelse continue;
            image.paste(pixels, room_width, room_height, origins[p].x + rect.x, origins[p].y + rect.y);
        }
    }

    const tags = try allocator.alloc(Tag, 2 * level.joins.len);
    errdefer allocator.free(tags);
    for (level.joins, 0..) |join, i| {
        const letter: u8 = @intCast('A' + i);
        switch (join) {
            .link => |link| {
                const from = roomOrigin(map, &origins, link.room);
                const to = roomOrigin(map, &origins, link.to);
                const a = edge(link.side);
                const b = edge(map_mod.opposite(link.side));
                tags[2 * i] = .{ .letter = letter, .x = from.x + a.x, .y = from.y + a.y };
                tags[2 * i + 1] = .{ .letter = letter, .x = to.x + b.x, .y = to.y + b.y };
            },
            .transport => |t| {
                const from = roomOrigin(map, &origins, t.from.room);
                const to = roomOrigin(map, &origins, t.to.room);
                // Above the characters' feet.
                tags[2 * i] = .{ .letter = letter, .x = from.x + t.from.x, .y = from.y + t.from.y - 48 };
                tags[2 * i + 1] = .{ .letter = letter, .x = to.x + t.to.x, .y = to.y + t.to.y - 48 };
            },
        }
    }
    return .{ .image = image, .tags = tags };
}

/// Where a room's top-left is on its level's block.
fn roomOrigin(map: *const map_mod.Map, origins: []const pack_mod.Point, room: u8) pack_mod.Point {
    const cell = map.cells[room].?;
    const origin = origins[cell.piece];
    return .{ .x = origin.x + cell.x * room_width, .y = origin.y + cell.y * room_pitch };
}

/// The middle of a room's edge on `side`, from the room's top-left.
fn edge(side: map_mod.Side) pack_mod.Point {
    return switch (side) {
        .up => .{ .x = room_width / 2, .y = 0 },
        .down => .{ .x = room_width / 2, .y = room_pitch + (room_height - room_pitch) / 2 },
        .right => .{ .x = room_width, .y = room_pitch / 2 },
        .left => .{ .x = 0, .y = room_pitch / 2 },
    };
}
