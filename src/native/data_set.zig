//! The data set the game runs on (DESIGN.md section 3): read from a directory the user chose,
//! or extracted in memory from the original files when no directory is given.
const std = @import("std");
const flashbackz = @import("flashbackz");
const extract = @import("extract");
const Files = flashbackz.behavior.data_set.Files;

/// Every `.zon` file under `path`, by its path relative to `path` with `/` separators.
/// Results live in `arena`.
pub fn readDirectory(arena: std.mem.Allocator, io: std.Io, path: []const u8) !Files {
    var root = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer root.close(io);
    var walker = try root.walk(arena);
    defer walker.deinit();
    var files: Files = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zon")) continue;
        const name = try arena.dupe(u8, entry.path);
        std.mem.replaceScalar(u8, name, std.fs.path.sep, '/');
        const text = try root.readFileAllocOptions(
            io,
            entry.path,
            arena,
            .limited(8 << 20),
            .of(u8),
            0,
        );
        try files.put(arena, name, text);
    }
    return files;
}

/// Extracts the data set from the original files with the built-in naming overlay.
pub fn extractInMemory(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    source: flashbackz.platform.AssetSource,
) !Files {
    var collector: Collector = .{ .arena = arena };
    _ = try extract.extractAll(gpa, arena, source, extract.built_in_names, .{
        .context = &collector,
        .put = Collector.put,
    });
    return collector.files;
}

const Collector = struct {
    arena: std.mem.Allocator,
    files: Files = .empty,

    fn put(context: *anyopaque, path: []const u8, bytes: []const u8) anyerror!void {
        const self: *Collector = @ptrCast(@alignCast(context));
        if (!std.mem.endsWith(u8, path, ".zon")) return;
        const text = try self.arena.dupeSentinel(u8, bytes, 0);
        try self.files.put(self.arena, try self.arena.dupe(u8, path), text);
    }
};

test "a data set directory is read by relative path, ZON files only" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "city/behaviors");
    try tmp.dir.writeFile(io, .{ .sub_path = "city/characters.zon", .data = ".{}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "city/behaviors/guard.zon", .data = ".{ .a = 1 }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "report.txt", .data = "notes" });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const files = try readDirectory(arena.allocator(), io, path_buf[0..len]);
    try std.testing.expectEqual(@as(usize, 2), files.count());
    try std.testing.expectEqualStrings(".{}", files.get("city/characters.zon").?);
    try std.testing.expectEqualStrings(".{ .a = 1 }", files.get("city/behaviors/guard.zon").?);
}
