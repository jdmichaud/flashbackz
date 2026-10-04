//! The command-line options that both native hosts take and open for the game: a positional
//! asset paths and `--saves <dir>`.
//!
//! Each asset path is a directory or a FAT12 floppy image. `--saves` defaults to the per-user application data directory, which
//! is created on first use. The result is a bound `AssetSource` and `Storage`. The game uses
//! them and does not know which kind of source it has.
const std = @import("std");
const builtin = @import("builtin");
const flashbackz = @import("flashbackz");
const platform = flashbackz.platform;
const DirectoryAssetSource = @import("directory.zig").DirectoryAssetSource;
const DirectoryStorage = @import("storage.zig").DirectoryStorage;
const Pack = flashbackz.asset_pack.Pack;

pub const usage =
    \\  ASSET_PATH    FAT12 IMG/IMA images or extracted directories; repeat for all disks
    \\  --scene NAME   development shortcut: menu or a level name (default: normal startup)
    \\  --saves DIR    where saves are kept (default: the per-user application data directory)
    \\
;

pub const TakeError = error{ MissingValue, TooManyAssets, UnknownScene };

pub const Options = struct {
    assets: ?[]const u8 = null,
    additional_assets: [7][]const u8 = undefined,
    additional_count: usize = 0,
    saves: ?[]const u8 = null,
    entry: flashbackz.game.Entry = .automatic,

    /// Consumes `--saves` and positional asset paths. Returns false for
    /// any other argument. After `--`, an asset path can start with a dash.
    pub fn take(self: *Options, arg: []const u8, args: anytype) TakeError!bool {
        if (std.mem.eql(u8, arg, "--scene")) {
            const value = args.next() orelse return error.MissingValue;
            self.entry = if (std.mem.eql(u8, value, "jungle")) .jungle_development else if (std.mem.eql(u8, value, "menu")) .menu_development else if (std.meta.stringToEnum(flashbackz.content.level.Id, value)) |level| .{ .level_development = level } else return error.UnknownScene;
            return true;
        }
        if (std.mem.eql(u8, arg, "--saves")) {
            const value = args.next() orelse return error.MissingValue;
            if (value.len == 0) return error.MissingValue;
            self.saves = value;
            return true;
        }
        if (std.mem.eql(u8, arg, "--")) {
            while (args.next()) |path| try self.addAsset(path);
            return true;
        }
        if (arg.len == 0 or arg[0] != '-') {
            try self.addAsset(arg);
            return true;
        }
        return false;
    }

    pub fn addAsset(self: *Options, path: []const u8) error{ MissingValue, TooManyAssets }!void {
        if (path.len == 0) return error.MissingValue;
        if (self.assets == null) {
            self.assets = path;
        } else {
            if (self.additional_count >= self.additional_assets.len) return error.TooManyAssets;
            self.additional_assets[self.additional_count] = path;
            self.additional_count += 1;
        }
    }
};

/// The kind of asset source, for the host's start-up line and the agent's diagnostics.
pub const AssetKind = enum { none, directory, floppy, mixed };

pub const OpenError = error{
    NotFound,
    NotADirectory,
    InvalidImage,
    ConflictingAsset,
    AccessDenied,
    NoApplicationDirectory,
    Io,
    Canceled,
    OutOfMemory,
};

/// The providers that a host owns while the game runs.
pub const Providers = struct {
    allocator: std.mem.Allocator = undefined,
    kind: AssetKind = .none,
    /// The save directory in use (owned).
    saves_path: []u8 = &.{},
    content: ?Pack = null,
    saves: ?DirectoryStorage = null,

    pub const empty: Providers = .{};

    /// Opens the save directory, and creates it if it does not exist. If the options give an
    /// asset path, also opens the asset source at that path.
    pub fn open(
        self: *Providers,
        allocator: std.mem.Allocator,
        io: std.Io,
        environ: *const std.process.Environ.Map,
        options: Options,
    ) OpenError!void {
        self.allocator = allocator;
        errdefer self.deinit();
        self.saves_path = if (options.saves) |path|
            try allocator.dupe(u8, path)
        else
            try defaultSaveDirectory(allocator, environ);
        self.saves = try mapOpen(DirectoryStorage.open(allocator, io, self.saves_path, true));
        const path = options.assets orelse return;
        if (options.additional_count > options.additional_assets.len) return error.InvalidImage;
        self.content = Pack.init(allocator);
        try self.importPath(io, path);
        for (options.additional_assets[0..options.additional_count]) |additional| try self.importPath(io, additional);
        flashbackz.content.archive.expandAll(&self.content.?) catch |err| return mapImportError(err);
    }

    fn importPath(self: *Providers, io: std.Io, path: []const u8) OpenError!void {
        const allocator = self.allocator;
        const kind: AssetKind = if (DirectoryAssetSource.open(allocator, io, path)) |opened| directory: {
            var directory = opened;
            defer directory.deinit();
            const source = directory.assetSource();
            var listing = source.list("") catch return error.Io;
            defer listing.deinit();
            for (listing.names) |name| {
                // Refuse the superseded edition before reading large movies.
                if (platform.assetNameEql(name, "GAME_E.OVL")) return error.InvalidImage;
                var data = source.readAll(name, Pack.limit - self.content.?.total) catch return error.InvalidImage;
                defer data.deinit();
                self.content.?.add(name, data.bytes) catch |err| return mapImportError(err);
            }
            break :directory .directory;
        } else |err| image: {
            if (err != error.NotADirectory) return err;
            const image_bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024)) catch return error.InvalidImage;
            defer allocator.free(image_bytes);
            var imported = flashbackz.floppy.load(allocator, image_bytes) catch |failure| return mapImportError(failure);
            defer imported.deinit();
            self.content.?.merge(&imported) catch |failure| return mapImportError(failure);
            break :image .floppy;
        };
        self.kind = if (self.kind == .none or self.kind == kind) kind else .mixed;
    }

    fn mapImportError(err: anyerror) OpenError {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            error.ConflictingAsset => error.ConflictingAsset,
            else => error.InvalidImage,
        };
    }

    fn mapOpen(result: anytype) OpenError!@typeInfo(@TypeOf(result)).error_union.payload {
        return result catch |err| switch (err) {
            error.NotFound => error.NotFound,
            error.NotADirectory => error.NotADirectory,
            error.AccessDenied => error.AccessDenied,
            error.Canceled => error.Canceled,
            error.Io => error.Io,
        };
    }

    pub fn deinit(self: *Providers) void {
        if (self.content) |*content| content.deinit();
        if (self.saves) |*s| s.deinit();
        self.allocator.free(self.saves_path);
        self.* = .empty;
    }

    /// The bound asset source. Null when the host has no asset path and uses its own assets.
    pub fn assetSource(self: *Providers) ?platform.AssetSource {
        return if (self.content) |*content| content.assetSource() else null;
    }

    pub fn storage(self: *Providers) platform.Storage {
        return self.saves.?.storage();
    }
};

/// The per-user application data directory for the flashbackz saves:
/// `$XDG_DATA_HOME/flashbackz/saves`, else `$HOME/.local/share/flashbackz/saves`, and
/// `%APPDATA%\flashbackz\saves` on Windows. The caller owns the result.
pub fn defaultSaveDirectory(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) OpenError![]u8 {
    if (builtin.os.tag == .windows) {
        const appdata = environ.get("APPDATA") orelse return error.NoApplicationDirectory;
        if (appdata.len == 0) return error.NoApplicationDirectory;
        return std.fmt.allocPrint(allocator, "{s}\\flashbackz\\saves", .{appdata}) catch return error.OutOfMemory;
    }
    if (environ.get("XDG_DATA_HOME")) |data_home| {
        if (data_home.len != 0) {
            return std.fmt.allocPrint(allocator, "{s}/flashbackz/saves", .{data_home}) catch return error.OutOfMemory;
        }
    }
    const home = environ.get("HOME") orelse return error.NoApplicationDirectory;
    if (home.len == 0) return error.NoApplicationDirectory;
    return std.fmt.allocPrint(allocator, "{s}/.local/share/flashbackz/saves", .{home}) catch return error.OutOfMemory;
}

const contract = @import("contract.zig");

fn testEnviron(allocator: std.mem.Allocator, pairs: []const [2][]const u8) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(allocator);
    for (pairs) |pair| try map.put(pair[0], pair[1]);
    return map;
}

test "the save directory follows the platform's application data convention" {
    const allocator = std.testing.allocator;
    {
        var env = try testEnviron(allocator, &.{.{ "XDG_DATA_HOME", "/data" }});
        defer env.deinit();
        if (builtin.os.tag == .windows) {
            // Windows reads %APPDATA% only.
            try std.testing.expectError(error.NoApplicationDirectory, defaultSaveDirectory(allocator, &env));
        } else {
            const path = try defaultSaveDirectory(allocator, &env);
            defer allocator.free(path);
            try std.testing.expectEqualStrings("/data/flashbackz/saves", path);
        }
    }
    {
        var env = try testEnviron(allocator, &.{ .{ "HOME", "/home/player" }, .{ "APPDATA", "C:\\Users\\player\\AppData\\Roaming" } });
        defer env.deinit();
        const path = try defaultSaveDirectory(allocator, &env);
        defer allocator.free(path);
        const want = if (builtin.os.tag == .windows)
            "C:\\Users\\player\\AppData\\Roaming\\flashbackz\\saves"
        else
            "/home/player/.local/share/flashbackz/saves";
        try std.testing.expectEqualStrings(want, path);
    }
    {
        var env = try testEnviron(allocator, &.{});
        defer env.deinit();
        try std.testing.expectError(error.NoApplicationDirectory, defaultSaveDirectory(allocator, &env));
    }
}

test "the options open a game directory, or none" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = path_buf[0..try tmp.dir.realPath(io, &path_buf)];

    try tmp.dir.createDirPath(io, "game");
    var game_dir = try tmp.dir.openDir(io, "game", .{ .iterate = true });
    defer game_dir.close(io);
    try @import("directory.zig").writeFixture(io, game_dir);

    var env = try testEnviron(allocator, &.{.{ "XDG_DATA_HOME", "/unused" }});
    defer env.deinit();
    var paths: [2][]u8 = undefined;
    inline for (.{ "game", "saves" }, 0..) |sub, i| {
        paths[i] = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, sub });
    }
    defer for (paths) |p| allocator.free(p);

    // A game directory: the asset source passes the contract, and the storage keeps a record.
    {
        var providers: Providers = .empty;
        try providers.open(allocator, io, &env, .{ .assets = paths[0], .saves = paths[1] });
        defer providers.deinit();
        try std.testing.expect(providers.kind != .none);
        try contract.assetContract(providers.assetSource().?);
        const s = providers.storage();
        try s.save("CLI.PT", "position");
        var loaded = try s.load("CLI.PT");
        defer loaded.deinit();
        try std.testing.expectEqualStrings("position", loaded.bytes);
        try s.deleteSave("CLI.PT");
    }

    // Without an asset path, only the save directory opens, and `open` creates it.
    {
        var providers: Providers = .empty;
        try providers.open(allocator, io, &env, .{ .saves = paths[1] });
        defer providers.deinit();
        try std.testing.expectEqual(AssetKind.none, providers.kind);
        try std.testing.expect(providers.assetSource() == null);
        var names = try providers.storage().listSaves();
        names.deinit();
        try std.testing.expectEqualStrings(paths[1], providers.saves_path);
    }

    // A path that is missing, or not a directory.
    {
        var providers: Providers = .empty;
        const missing = try std.fmt.allocPrint(allocator, "{s}/absent", .{base});
        defer allocator.free(missing);
        try std.testing.expectError(error.NotFound, providers.open(allocator, io, &env, .{ .assets = missing, .saves = paths[1] }));
        const not_a_directory = try std.fmt.allocPrint(allocator, "{s}/game/game.cfg", .{base});
        defer allocator.free(not_a_directory);
        try std.testing.expectError(error.InvalidImage, providers.open(allocator, io, &env, .{ .assets = not_a_directory, .saves = paths[1] }));
    }
}

test "the positional source reads a floppy through owned provider storage" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const image = try flashbackz.floppy.testImage(allocator);
    defer allocator.free(image);
    try tmp.dir.writeFile(io, .{ .sub_path = "game.ima", .data = image });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = path_buffer[0..try tmp.dir.realPath(io, &path_buffer)];
    var env = try testEnviron(allocator, &.{});
    defer env.deinit();
    const saves = try std.fmt.allocPrint(allocator, "{s}/saves", .{base});
    defer allocator.free(saves);
    const path = try std.fmt.allocPrint(allocator, "{s}/game.ima", .{base});
    defer allocator.free(path);
    var providers: Providers = .empty;
    try providers.open(allocator, io, &env, .{ .assets = path, .saves = saves });
    defer providers.deinit();
    try std.testing.expectEqual(AssetKind.floppy, providers.kind);
    var content = try providers.assetSource().?.readAll("data/file.dat", 600);
    defer content.deinit();
    try std.testing.expectEqual(@as(usize, 600), content.bytes.len);
}

test "multiple disks merge files and conflicting editions fail without partial providers" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const image = try flashbackz.floppy.testImage(allocator);
    defer allocator.free(image);
    try tmp.dir.writeFile(io, .{ .sub_path = "first.img", .data = image });
    @memcpy(image[33 * 512 ..][0..11], "SECOND  DAT");
    try tmp.dir.writeFile(io, .{ .sub_path = "second.img", .data = image });
    @memcpy(image[33 * 512 ..][0..11], "FILE    DAT");
    image[35 * 512] = 'X';
    try tmp.dir.writeFile(io, .{ .sub_path = "conflict.img", .data = image });
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = path_buffer[0..try tmp.dir.realPath(io, &path_buffer)];
    var paths: [4][]u8 = undefined;
    inline for (.{ "first.img", "second.img", "conflict.img", "saves" }, 0..) |name, i| {
        paths[i] = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, name });
    }
    defer for (paths) |path| allocator.free(path);
    var env = try testEnviron(allocator, &.{});
    defer env.deinit();
    var options: Options = .{ .saves = paths[3] };
    try options.addAsset(paths[0]);
    try options.addAsset(paths[1]);
    {
        var providers: Providers = .empty;
        try providers.open(allocator, io, &env, options);
        defer providers.deinit();
        var names = try providers.assetSource().?.list("");
        defer names.deinit();
        try std.testing.expectEqual(@as(usize, 2), names.names.len);
        try std.testing.expectEqualStrings("DATA/FILE.DAT", names.names[0]);
        try std.testing.expectEqualStrings("DATA/SECOND.DAT", names.names[1]);
        var first = try providers.assetSource().?.readAll(names.names[0], 600);
        defer first.deinit();
        var second = try providers.assetSource().?.readAll(names.names[1], 600);
        defer second.deinit();
        try std.testing.expectEqualSlices(u8, first.bytes, second.bytes);
    }
    try options.addAsset(paths[2]);
    var failed: Providers = .empty;
    try std.testing.expectError(error.ConflictingAsset, failed.open(allocator, io, &env, options));
    try std.testing.expect(failed.content == null and failed.saves == null);
    var bounded: Options = .{};
    for (0..8) |_| try bounded.addAsset("disk.img");
    try std.testing.expectError(error.TooManyAssets, bounded.addAsset("extra.img"));
}
