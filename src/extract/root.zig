//! The extractor: it reads the original's tables from the user's disks and writes the readable
//! data set (DESIGN.md section 3). Images and sound are not extracted: the game reads them from
//! the originals. `extractAll` runs these stages in this order:
//! 1. `names.parse` reads the naming overlay.
//! 2. `floppy_interface.load` reads the tables of the game executable.
//! 3. For each level, `level.extract` writes `LEVEL/characters.zon` and `LEVEL/behaviors/*.zon`.
//! 4. `writeMessages` writes `messages.zon`, then `writeScenes` writes `scenes.zon`.
//! 5. The counts and the notes go to `report.txt`.
//! Each file goes to `Output.put` (the sinks are in native/data_set.zig). With `--extract`,
//! `DirectoryWriter` writes every file into a directory. The extraction in memory (`Collector`)
//! keeps only the `.zon` files.
const std = @import("std");
const flashbackz = @import("flashbackz");
const level = @import("level.zig");
const names = @import("names.zig");
const zon = @import("zon.zig");
const world_messages = @import("world_messages.zig");

pub const Output = level.Output;
pub const Report = level.Report;

/// The naming overlay built into the extractor.
pub const built_in_names: [:0]const u8 = @embedFile("names.zon");

/// Extracts every level, the world messages and the scenes into `output`, named as in the data
/// set (`city/characters.zon`, `city/behaviors/NAME.zon`, `messages.zon`, `scenes.zon`,
/// `report.txt`).
pub fn extractAll(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    source: flashbackz.platform.AssetSource,
    names_source: [:0]const u8,
    output: Output,
) !Report {
    const overlay = try names.parse(gpa, arena, names_source);
    const interface = try flashbackz.content.floppy_interface.load(gpa, source);
    var report: Report = .{};
    for (std.enums.values(flashbackz.content.level.Id)) |id| {
        const basename = flashbackz.content.level.files(id).actors;
        var placements = try read(source, basename, "PGE", 16 * 1024);
        defer placements.deinit();
        var rules = try read(source, basename, "OBJ", 256 * 1024);
        defer rules.deinit();
        var labels = try read(source, basename, "TBN", 16 * 1024);
        defer labels.deinit();
        try level.extract(
            arena,
            .{
                .name = @tagName(id),
                .placements = placements.bytes,
                .rules = rules.bytes,
                .labels = labels.bytes,
                .score_awards = interface.score_awards,
                .library_groups = interface.library_groups[@backingInt(id)],
                .overlay = overlay,
            },
            output,
            &report,
        );
    }
    try writeMessages(arena, source, output);
    try writeScenes(arena, &interface, output);
    var summary: std.Io.Writer.Allocating = .init(arena);
    try summary.writer.print(
        \\Extracted {d} characters and {d} behaviors; the overlay names {d} behaviors and {d} of
        \\the {d} states.
        \\Dropped {d} unreachable rules; {d} operations had an argument the original ignores.
        \\
    , .{
        report.characters,
        report.behaviors,
        report.named_behaviors,
        report.named_states,
        report.states,
        report.dead_rules,
        report.ignored_arguments,
    });
    try summary.writer.writeAll(report.notes.items);
    try output.put(output.context, "report.txt", summary.written());
    return report;
}

fn read(
    source: flashbackz.platform.AssetSource,
    basename: []const u8,
    extension: []const u8,
    limit: usize,
) !flashbackz.platform.OwnedBytes {
    var path: [64]u8 = undefined;
    return source.readAll(
        try std.fmt.bufPrint(&path, "DATA/{s}.{s}", .{ basename, extension }),
        limit,
    );
}

/// `scenes.zon`: the scene of each level when it starts, the film of each scene, and the ending.
fn writeScenes(
    arena: std.mem.Allocator,
    interface: *const flashbackz.content.floppy_interface.Values,
    sink: level.Output,
) !void {
    var text: std.Io.Writer.Allocating = .init(arena);
    var w: zon.Writer = .{ .out = &text.writer };
    try text.writer.writeAll(
        \\// Generated with --extract from the user's game files. Do not commit.
        \\// A scene is a numbered request for a film: a level makes one when it starts,
        \\// and a rule makes one with play_scene. The sections:
        \\// - openings: the scene of each level when it starts (null: none).
        \\// - films: the film of each scene, by number: its name, entry and music (null: none).
        \\// - ending: the scenes that the ending plays after scene 61, and its credits.
        \\
    );
    try w.open(null);
    try w.open("openings");
    for (std.enums.values(flashbackz.content.level.Id), interface.level_scenes) |id, scene| {
        if (scene) |number| {
            try w.line(".{s} = {d},", .{ @tagName(id), number });
        } else {
            try w.line(".{s} = null,", .{ @tagName(id) });
        }
    }
    try w.close();
    try w.open("films");
    for (interface.scenes, 0..) |scene, number| {
        const film = std.mem.sliceTo(&scene.film, 0);
        if (film.len == 0) {
            try w.line("null, // scene {d}", .{ number });
            continue;
        }
        var fields: std.Io.Writer.Allocating = .init(arena);
        try fields.writer.print(".film = {f}, .entry = {d}", .{ zon.string(film), scene.entry });
        const music = std.mem.sliceTo(&scene.music, 0);
        if (music.len != 0) {
            try fields.writer.print(", .music = {f}", .{ zon.string(music) });
        }
        if (scene.flagged) {
            try fields.writer.writeAll(", .flagged = true");
        }
        try w.line(".{{ {s} }}, // scene {d}", .{ fields.written(), number });
    }
    try w.close();
    try writeEnding(&w, interface);
    try w.close();
    try sink.put(sink.context, "scenes.zon", text.written());
}

/// The scenes the ending plays after its first, and the credits typed over them: text (`|` starts
/// a new line), holds in timer ticks, positions in units of 8 pixels, and block ends.
fn writeEnding(w: *zon.Writer, interface: *const flashbackz.content.floppy_interface.Values) !void {
    try w.open("ending");
    try w.open("scenes");
    for (interface.ending_scenes[0..interface.ending_scene_count]) |scene| {
        try w.line("{d},", .{ scene });
    }
    try w.close();
    try w.open("credits");
    const stream = interface.credits[0..interface.credits_length];
    var at: usize = 0;
    while (at < stream.len) {
        switch (stream[at]) {
            0xff => break,
            0xfe => {
                if (at + 2 > stream.len) return error.TruncatedCredits;
                try w.line(".{{ .hold = {d} }},", .{ stream[at + 1] });
                at += 2;
            },
            0x01 => {
                if (at + 3 > stream.len) return error.TruncatedCredits;
                try w.line(".{{ .at = .{{ .column = {d}, .row = {d} }} }},", .{
                    stream[at + 1],
                    stream[at + 2],
                });
                at += 3;
            },
            0x00 => {
                try w.line(".block_end,", .{});
                at += 1;
            },
            else => {
                const end = std.mem.indexOfAny(
                    u8,
                    stream[at..],
                    &.{ 0x00, 0x01, 0xfe, 0xff },
                ) orelse
                    stream.len - at;
                try w.line(".{{ .text = {f} }},", .{ zon.string(stream[at..][0..end]) });
                at += end;
            },
        }
    }
    try w.close();
    try w.close();
}

/// World messages, indexed as `show_message` refers to them.
fn writeMessages(
    arena: std.mem.Allocator,
    source: flashbackz.platform.AssetSource,
    sink: level.Output,
) !void {
    var messages = try world_messages.load(arena, source);
    defer messages.deinit();
    var text: std.Io.Writer.Allocating = .init(arena);
    var w: zon.Writer = .{ .out = &text.writer };
    try text.writer.writeAll(
        \\// Generated with --extract from the user's game files. Do not commit.
        \\// The world messages, by number: each is a list of pages, and each page a list
        \\// of lines, each with its text color (ink).
        \\
    );
    try w.open(null);
    for (messages.messages, 0..) |message, number| {
        try w.line("// message {d}", .{ number });
        try w.open(null);
        for (message.pages) |page| {
            try w.open(null);
            for (page.lines) |line| {
                try w.line(".{{ .text = {f}, .ink = {d} }},", .{ zon.string(line.text), line.ink });
            }
            try w.close();
        }
        try w.close();
    }
    try w.close();
    try sink.put(sink.context, "messages.zon", text.written());
}

test {
    _ = @import("codes.zig");
    _ = @import("key.zig");
    _ = @import("level.zig");
    _ = @import("names.zig");
    _ = @import("placement.zig");
    _ = @import("rule_table.zig");
    _ = @import("string_table.zig");
    _ = @import("world_messages.zig");
    _ = @import("zon.zig");
}
