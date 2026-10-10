//! flashbackz-atlas: draws every level of the user's game into one PNG poster, a row per level,
//! its name in the game font and its rooms placed by their links (map.zig, poster.zig). The
//! poster holds the game's art: it is the user's, written where they ask, never committed.
const std = @import("std");
const flashbackz = @import("flashbackz");
const native = @import("native");
const clap = native.clap;
const map = @import("map.zig");
const poster = @import("poster.zig");
const png = @import("png.zig");

const level_mod = flashbackz.content.level;
const data_set = flashbackz.behavior.data_set;

const Args = clap.Parser(.{
    .name = "flashbackz-atlas",
    .description = "Draws every level's rooms into one PNG poster, from the game's floppy disks.",
    .options = &.{
        .{ .long = "output", .short = 'o', .value = "FILE", .help = "write the poster to FILE (default flashback-levels.png)" },
    },
    .positionals = &.{.{
        .name = "ASSET_PATH",
        .help = "a floppy image (IMG/IMA) or extracted directory; give both disks",
        .min = 1,
        .max = 2,
    }},
});

/// Each level's name on the poster, and the hue of its accent, taken from its own palette: the
/// jungle's foliage, the city's red district, the tower's blue, Earth's amber, the spaceport's
/// steel, the alien rock and the alien base's violet.
fn design(id: level_mod.Id) struct { name: []const u8, hue: f32 } {
    return switch (id) {
        .jungle => .{ .name = "JUNGLE", .hue = 88 },
        .city => .{ .name = "NEW WASHINGTON", .hue = 342 },
        .tower => .{ .name = "DEATH TOWER", .hue = 228 },
        .earth_city => .{ .name = "EARTH", .hue = 44 },
        .spaceport => .{ .name = "SPACEPORT", .hue = 202 },
        .alien_surface => .{ .name = "ALIEN SURFACE", .hue = 318 },
        .alien_base => .{ .name = "ALIEN BASE", .hue = 268 },
    };
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    var stderr_buffer: [512]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &stderr_buffer);
    const err_out = &stderr.interface;

    var diagnostic: clap.Diagnostic = .{};
    const args = Args.parse(arena, try clap.processArguments(arena, init.minimal.args), &diagnostic) catch |err| {
        try Args.writeError(err_out, err, diagnostic);
        try err_out.flush();
        return 2;
    };
    if (args.help) {
        var buffer: [2048]u8 = undefined;
        var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
        try Args.writeHelp(&stdout.interface);
        try stdout.interface.flush();
        return 0;
    }
    const output = args.value("output") orelse "flashback-levels.png";

    var providers: native.Providers = .empty;
    defer providers.deinit();
    providers.openAssets(gpa, io, args.positional("ASSET_PATH")) catch |err| {
        try err_out.writeAll("flashbackz-atlas: ");
        try providers.writeFailure(err, err_out);
        try err_out.flush();
        return 1;
    };
    const source = providers.assetSource().?;

    var data_arena: std.heap.ArenaAllocator = .init(gpa);
    defer data_arena.deinit();
    const files = native.data_set.extractInMemory(gpa, data_arena.allocator(), source) catch |err| {
        try err_out.print("flashbackz-atlas: cannot read the levels from the disks: {s}\n", .{@errorName(err)});
        try err_out.flush();
        return 1;
    };
    const interface = try flashbackz.content.floppy_interface.load(gpa, source);
    var font_file = try source.readAll("DATA/FB_TXT.FNT", 16384);
    defer font_file.deinit();
    var font = try flashbackz.content.font.decode(gpa, font_file.bytes);
    defer font.deinit();

    const ids = std.enums.values(level_mod.Id);
    var data: [ids.len]data_set.Level = undefined;
    var starts: [ids.len]map.RoomSet = undefined;
    for (ids, &data, &starts) |id, *level, *rooms| {
        var level_diagnostic: data_set.Diagnostic = .{};
        level.* = data_set.loadLevel(gpa, data_arena.allocator(), &files, @tagName(id), &level_diagnostic) catch |err| {
            try err_out.print("flashbackz-atlas: {s}: {s}\n", .{ @tagName(id), level_diagnostic.message() });
            try err_out.flush();
            return err;
        };
        rooms.* = .empty;
        for (level.characters) |character| {
            if (character.room) |room| if (room < map.room_count) rooms.set(room);
        }
    }

    var levels: [ids.len]poster.Level = undefined;
    var joins: [ids.len]std.ArrayList(map.Join) = @splat(.empty);
    var pixels: std.ArrayList([]u8) = .empty;
    defer {
        for (&joins) |*list| list.deinit(gpa);
        for (pixels.items) |p| gpa.free(p);
        pixels.deinit(gpa);
    }
    for (ids, 0..) |id, i| {
        const start = data[i].characters[0].room orelse 0;
        var pack = try flashbackz.content.level_pack.load(gpa, source, &interface, id, .normal, start);
        defer pack.deinit();
        var present: map.RoomSet = .empty;
        for (pack.rooms, 0..) |room, index| if (room != null) present.set(index);
        const links: map.Links = .fromGrid(&pack.grid, present);
        const owned = map.owned(&links, starts[i], sharer(ids, i, &starts));
        var rooms: map.Pixels = @splat(null);
        var drawn = owned.iterator(.{});
        while (drawn.next()) |room| {
            const art = pack.room(@intCast(room)).?;
            // The poster lays rooms out at the size the game draws them.
            if (art.image.width != map.room_width or art.image.height != map.room_height)
                return error.UnexpectedRoomSize;
            const rgb = try gpa.alloc(u8, art.image.pixels.len * 3);
            try pixels.append(gpa, rgb);
            for (art.image.pixels, 0..) |index, p| {
                const color = art.colors[index];
                rgb[p * 3 ..][0..3].* = .{ color.r, color.g, color.b };
            }
            rooms[room] = rgb;
        }
        // A level drawn along its transit line carries no tags; the others' joins are tagged.
        const line = map.transitLine(&links, owned, &rooms);
        const skipped: map.Skipped = if (line) |*l| l.skipped(&links) else @splat(@splat(false));
        const level_map = map.lay(&links, owned, start, &skipped);
        if (line == null) {
            try map.cutLinks(gpa, &links, &level_map, &joins[i]);
            try map.transports(gpa, &data[i], &level_map, &joins[i]);
        }
        const look = design(id);
        levels[i] = .{
            .name = look.name,
            .hue = look.hue,
            .rooms = rooms,
            .map = level_map,
            .line = line,
            .joins = joins[i].items,
        };
    }

    var canvas = try poster.render(gpa, &font, &levels);
    defer canvas.deinit(gpa);
    var file = std.Io.Dir.cwd().createFile(io, output, .{}) catch |err| {
        try err_out.print("flashbackz-atlas: cannot write {s}: {s}\n", .{ output, @errorName(err) });
        try err_out.flush();
        return 1;
    };
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writerStreaming(io, &buffer);
    try png.write(gpa, &writer.interface, canvas.width, canvas.height, canvas.rgb);
    try writer.interface.flush();
    var stdout_buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    try stdout.interface.print("{s}: {d}x{d}\n", .{ output, canvas.width, canvas.height });
    try stdout.interface.flush();
    return 0;
}

/// The character rooms of the level sharing level `i`'s room file, if one does.
fn sharer(ids: []const level_mod.Id, i: usize, starts: []const map.RoomSet) ?map.RoomSet {
    const rooms = level_mod.files(ids[i]).rooms;
    for (ids, 0..) |other, j| {
        if (j != i and std.mem.eql(u8, level_mod.files(other).rooms, rooms)) return starts[j];
    }
    return null;
}

test {
    std.testing.refAllDecls(@This());
    _ = map;
    _ = @import("pack.zig");
    _ = @import("draw.zig");
    _ = poster;
    _ = png;
}
