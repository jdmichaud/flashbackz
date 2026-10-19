//! The films' files in the data set (DESIGN.md 3, PLAN FL-1). The extractor copies them unchanged
//! into the data set's `films/` directory, where a user can replace them: each film's CMD and POL
//! files, and the captions' ENGCINE.BIN and ENGCINE.TXT. `GameFiles` is the asset source that the
//! game reads when it has a data set: the data set's film files under their original names, and
//! the original's files for every other name.
const std = @import("std");
const platform = @import("platform.zig");
const data_set = @import("behavior/data_set.zig");

/// The data set's directory of the films' files.
pub const directory = "films/";

/// The original's directory of the films' files.
const original_directory = "DATA/";

/// Whether `name`, an original asset name such as `DATA/LOGOS.CMD`, is a film's file: a CMD or
/// POL file in `DATA/`, or one of the captions' two files. The comparison ignores case.
pub fn isFilmFile(name: []const u8) bool {
    if (!platform.assetNameStartsWith(name, original_directory)) return false;
    return isFilmFileName(name[original_directory.len..]);
}

/// Whether `path`, a path of the data set, is a film's file in `films/`.
pub fn isDataSetFile(path: []const u8) bool {
    if (!platform.assetNameStartsWith(path, directory)) return false;
    return isFilmFileName(path[directory.len..]);
}

/// A file name (no directory) of a film's file.
fn isFilmFileName(base: []const u8) bool {
    if (std.mem.indexOfScalar(u8, base, '/') != null) return false;
    return std.ascii.endsWithIgnoreCase(base, ".CMD") or
        std.ascii.endsWithIgnoreCase(base, ".POL") or
        std.ascii.eqlIgnoreCase(base, "ENGCINE.BIN") or
        std.ascii.eqlIgnoreCase(base, "ENGCINE.TXT");
}

/// The data set's path of the film's file `name` (`DATA/LOGOS.CMD` gives `films/LOGOS.CMD`).
pub fn dataSetPath(name: []const u8, buffer: []u8) error{ NoSpaceLeft }![]const u8 {
    return std.fmt.bufPrint(buffer, directory ++ "{s}", .{ name[original_directory.len..] });
}

/// The asset source of a game with a data set: the films' files from the data set, every other
/// file from the original's. A film's file that the data set does not have is not found, also
/// when the original has it: the data set holds the films the game plays.
pub const GameFiles = struct {
    allocator: std.mem.Allocator,
    original: platform.AssetSource,
    data: *const data_set.Files,
    /// The open files by slot: a handle is its slot plus one, so a handle is never zero.
    slots: std.ArrayList(?Open) = .empty,

    const Open = union(enum) {
        /// A film's file of the data set: its bytes.
        film: []const u8,
        /// A file of the original: the original's handle.
        original: platform.AssetHandle,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        original: platform.AssetSource,
        data: *const data_set.Files,
    ) GameFiles {
        return .{ .allocator = allocator, .original = original, .data = data };
    }

    pub fn deinit(self: *GameFiles) void {
        for (self.slots.items) |slot| {
            if (slot) |open_file| {
                switch (open_file) {
                    .original => |handle| self.original.close(handle),
                    .film => {},
                }
            }
        }
        self.slots.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn assetSource(self: *GameFiles) platform.AssetSource {
        return .{ .context = self, .vtable = &vtable, .allocator = self.allocator };
    }

    const vtable = platform.AssetSource.VTable{
        .open = open,
        .read_at = readAt,
        .list = list,
        .close = close,
    };

    fn open(context: *anyopaque, path: []const u8) platform.AssetError!platform.OpenedAsset {
        const self: *GameFiles = @ptrCast(@alignCast(context));
        if (isFilmFile(path)) {
            const bytes = self.film(path) orelse return error.NotFound;
            return .{ .handle = try self.take(.{ .film = bytes }), .length = bytes.len };
        }
        const opened = try self.original.open(path);
        errdefer self.original.close(opened.handle);
        return .{
            .handle = try self.take(.{ .original = opened.handle }),
            .length = opened.length,
        };
    }

    /// The data set's bytes of the film's file `path`, whatever the case of its name.
    fn film(self: *const GameFiles, path: []const u8) ?[]const u8 {
        var buffer: [platform.max_name_len + directory.len]u8 = undefined;
        const wanted = dataSetPath(path, &buffer) catch return null;
        for (self.data.keys(), self.data.values()) |name, bytes| {
            if (platform.assetNameEql(name, wanted)) return bytes;
        }
        return null;
    }

    fn take(self: *GameFiles, open_file: Open) platform.AssetError!platform.AssetHandle {
        const slot = for (self.slots.items, 0..) |existing, i| {
            if (existing == null) break i;
        } else grow: {
            self.slots.append(self.allocator, null) catch return error.OutOfMemory;
            break :grow self.slots.items.len - 1;
        };
        self.slots.items[slot] = open_file;
        return @fromBackingInt(@as(u32, @intCast(slot + 1)));
    }

    fn slotOf(self: *const GameFiles, handle: platform.AssetHandle) ?Open {
        const raw = @backingInt(handle);
        if (raw == 0 or raw > self.slots.items.len) return null;
        return self.slots.items[raw - 1];
    }

    fn readAt(
        context: *anyopaque,
        handle: platform.AssetHandle,
        offset: u64,
        dst: []u8,
    ) platform.AssetError!usize {
        const self: *GameFiles = @ptrCast(@alignCast(context));
        switch (self.slotOf(handle) orelse return error.InvalidHandle) {
            .original => |inner| return self.original.readAt(inner, offset, dst),
            .film => |bytes| {
                if (offset >= bytes.len) return 0;
                const start: usize = @intCast(offset);
                const count = @min(dst.len, bytes.len - start);
                @memcpy(dst[0..count], bytes[start..][0..count]);
                return count;
            },
        }
    }

    /// The original's names: the data set's films have the same names.
    fn list(
        context: *anyopaque,
        prefix: []const u8,
    ) platform.AssetError!platform.OwnedAssetEntries {
        const self: *GameFiles = @ptrCast(@alignCast(context));
        return self.original.list(prefix);
    }

    fn close(context: *anyopaque, handle: platform.AssetHandle) void {
        const self: *GameFiles = @ptrCast(@alignCast(context));
        const open_file = self.slotOf(handle) orelse return;
        if (open_file == .original) {
            self.original.close(open_file.original);
        }
        self.slots.items[@backingInt(handle) - 1] = null;
    }
};

test "the films' files are the CMD and POL files of DATA and the captions" {
    try std.testing.expect(isFilmFile("DATA/LOGOS.CMD"));
    try std.testing.expect(isFilmFile("data/logos.pol"));
    try std.testing.expect(isFilmFile("DATA/ENGCINE.TXT"));
    try std.testing.expect(isFilmFile("DATA/ENGCINE.BIN"));
    try std.testing.expect(!isFilmFile("DATA/FB_TXT.FNT"));
    try std.testing.expect(!isFilmFile("DATA/OTHER.BIN"));
    try std.testing.expect(!isFilmFile("LOGOS.CMD"));
    try std.testing.expect(isDataSetFile("films/LOGOS.CMD"));
    try std.testing.expect(!isDataSetFile("films/sub/LOGOS.CMD"));
    try std.testing.expect(!isDataSetFile("city/characters.zon"));
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings(
        "films/LOGOS.CMD",
        try dataSetPath("DATA/LOGOS.CMD", &buffer),
    );
}

test "the game's files: the data set's films, the original's other files" {
    const memory = @import("memory.zig");
    const allocator = std.testing.allocator;
    var original = memory.MemoryAssetSource.init(allocator);
    defer original.deinit();
    try original.add("DATA/LOGOS.CMD", "original film");
    try original.add("DATA/INTRO1.CMD", "only in the original");
    try original.add("DATA/FB_TXT.FNT", "font");
    var data: data_set.Files = .empty;
    defer data.deinit(allocator);
    try data.put(allocator, "films/LOGOS.CMD", "edited film");
    try data.put(allocator, "scenes.zon", ".{}");
    var files: GameFiles = .init(allocator, original.assetSource(), &data);
    defer files.deinit();
    const source = files.assetSource();

    var edited = try source.readAll("data/logos.cmd", 64);
    defer edited.deinit();
    try std.testing.expectEqualStrings("edited film", edited.bytes);
    var font = try source.readAll("DATA/FB_TXT.FNT", 64);
    defer font.deinit();
    try std.testing.expectEqualStrings("font", font.bytes);
    // A film that the data set lacks is not found, though the original has it.
    try std.testing.expectError(error.NotFound, source.readAll("DATA/INTRO1.CMD", 64));
    try std.testing.expectError(error.NotFound, source.readAll("DATA/ABSENT.DAT", 64));

    // Handles of both kinds stay apart while open together, and short reads continue.
    const film_file = try source.open("DATA/LOGOS.CMD");
    const original_file = try source.open("DATA/FB_TXT.FNT");
    var part: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try source.readAt(film_file.handle, 7, &part));
    try std.testing.expectEqualStrings("film", &part);
    try std.testing.expectEqual(@as(usize, 4), try source.readAt(original_file.handle, 0, &part));
    try std.testing.expectEqualStrings("font", &part);
    try std.testing.expectEqual(@as(usize, 0), try source.readAt(film_file.handle, 11, &part));
    source.close(film_file.handle);
    source.close(original_file.handle);
    try std.testing.expectEqual(@as(u32, 0), original.open_count);
    try std.testing.expectError(error.InvalidHandle, source.readAt(film_file.handle, 0, &part));
}
