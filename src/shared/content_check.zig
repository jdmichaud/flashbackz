//! The game's content checked once, when the game starts (PLAN D6): the scenes, the films'
//! files of the data set (PLAN FL-1), and every film the scenes name. A film the game cannot run
//! fails here, with its
//! reason, rather than when play reaches it. A level checks its own data when it loads (the
//! data-set loader and `scenes/level.zig` `checkContent`), the ending its own: parsing every
//! level here would add a second to each start of a Debug build.
const std = @import("std");
const platform = @import("platform.zig");
const data_set = @import("behavior/data_set.zig");
const vector_cinematic = @import("content/vector_cinematic.zig");
const film_files = @import("film_files.zig");

pub fn check(
    allocator: std.mem.Allocator,
    assets: platform.AssetSource,
    files: *const data_set.Files,
) !void {
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A data set that an earlier build extracted has no films: the game reads them from there.
    const has_films = for (files.keys()) |name| {
        if (film_files.isDataSetFile(name)) break true;
    } else false;
    if (!has_films) {
        std.log.err("data set: no films in {s}; extract the data set again", .{
            film_files.directory,
        });
        return error.DataSetWithoutFilms;
    }
    var diagnostic: data_set.Diagnostic = .{};
    const scenes = data_set.loadScenes(allocator, arena, files, &diagnostic) catch |err| {
        std.log.err("data set: {s}", .{ diagnostic.message() });
        return err;
    };
    for (scenes.films, 0..) |maybe, scene| {
        const film = maybe orelse continue;
        // Scenes share films: each entry is imported once.
        const seen = for (scenes.films[0..scene]) |earlier| {
            const other = earlier orelse continue;
            if (other.entry == film.entry and std.mem.eql(u8, other.film, film.film)) break true;
        } else false;
        if (seen) continue;
        var movie = vector_cinematic.load(allocator, assets, film.film, film.entry) catch |err| {
            std.log.err("scene {d}: film {s} entry {d} cannot play: {s}", .{
                scene,
                film.film,
                film.entry,
                @errorName(err),
            });
            return err;
        };
        movie.deinit();
    }
}
