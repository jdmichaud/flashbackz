//! The poster's design: a row per level on black, its name in the game font right-aligned
//! against a gutter, its map to the right in its own light, the map's joins tagged with letters.
const std = @import("std");
const flashbackz = @import("flashbackz");
const map_mod = @import("map.zig");
const pack_mod = @import("pack.zig");
const draw = @import("draw.zig");
const Font = flashbackz.content.font.Font;

const room_width = map_mod.room_width;
const room_height = map_mod.room_height;
const room_pitch = map_mod.room_pitch;

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
    /// The drawn rooms' pixels.
    rooms: map_mod.Pixels,
    map: map_mod.Map,
    joins: []const map_mod.Join,
};

/// A level's map drawn as one image, and where its joins' tags go on it.
const Block = struct {
    image: draw.Image,
    tags: []Tag,
};
/// A tag on the block; when it would cover another, it moves along x, or else along y.
const Tag = struct { letter: u8, x: i32, y: i32, along_x: bool };

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

    // Joined rooms in different pieces pull their pieces together.
    var ties: [2 * map_mod.room_count]pack_mod.Tie = undefined;
    var tie_count: usize = 0;
    for (level.joins) |join| {
        const a, const b = ends(join);
        const piece_a = map.cells[a.room].?.piece;
        const piece_b = map.cells[b.room].?.piece;
        if (piece_a == piece_b or tie_count == ties.len) continue;
        ties[tie_count] = .{ .a = piece_a, .a_at = inPiece(map, a), .b = piece_b, .b_at = inPiece(map, b) };
        tie_count += 1;
    }
    var origins: [map_mod.room_count]pack_mod.Point = undefined;
    const size = pack_mod.pack(
        pieces[0..piece_count],
        ties[0..tie_count],
        map_limit,
        piece_gap,
        origins[0..piece_count],
    );
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
        for (ends(join), 0..) |end, n| {
            const origin = origins[map.cells[end.room].?.piece];
            const at = inPiece(map, end);
            tags[2 * i + n] = .{ .letter = @intCast('A' + i), .x = origin.x + at.x, .y = origin.y + at.y, .along_x = end.along_x };
        }
    }
    separate(tags);
    return .{ .image = image, .tags = tags };
}

/// One end of a join: its room, where in the room its tag goes, and which way the tag moves
/// if another is there.
const End = struct { room: u8, at: pack_mod.Point, along_x: bool };

fn ends(join: map_mod.Join) [2]End {
    return switch (join) {
        .link => |link| blk: {
            const across = link.side == .up or link.side == .down;
            break :blk .{
                .{ .room = link.room, .at = edge(link.side), .along_x = across },
                .{ .room = link.to, .at = edge(map_mod.opposite(link.side)), .along_x = across },
            };
        },
        // Above the characters' feet.
        .transport => |t| .{
            .{ .room = t.from.room, .at = .{ .x = t.from.x, .y = t.from.y - 48 }, .along_x = true },
            .{ .room = t.to.room, .at = .{ .x = t.to.x, .y = t.to.y - 48 }, .along_x = true },
        },
    };
}

/// Where a join's end is in its piece.
fn inPiece(map: *const map_mod.Map, end: End) pack_mod.Point {
    const cell = map.cells[end.room].?;
    return .{ .x = cell.x * room_width + end.at.x, .y = cell.y * room_pitch + end.at.y };
}

/// Moves each tag off the tags before it, along its edge, until none covers another.
fn separate(tags: []Tag) void {
    const spacing = draw.tag_size + 16;
    for (tags, 0..) |*t, i| {
        var moved = true;
        while (moved) {
            moved = false;
            for (tags[0..i]) |other| {
                if (@abs(t.x - other.x) >= spacing or @abs(t.y - other.y) >= spacing) continue;
                if (t.along_x) t.x = other.x + spacing else t.y = other.y + spacing;
                moved = true;
            }
        }
    }
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

test "a tag that would cover another moves along its edge" {
    var tags = [_]Tag{
        .{ .letter = 'A', .x = 100, .y = 100, .along_x = true },
        .{ .letter = 'B', .x = 104, .y = 96, .along_x = true },
        .{ .letter = 'C', .x = 300, .y = 100, .along_x = false },
    };
    separate(&tags);
    try std.testing.expectEqual(@as(i32, 100 + draw.tag_size + 16), tags[1].x);
    try std.testing.expectEqual(@as(i32, 96), tags[1].y);
    try std.testing.expectEqual(@as(i32, 300), tags[2].x);
}
