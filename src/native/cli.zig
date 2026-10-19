//! The options that both native hosts take, and the providers that open them for the game.
//! `clap` reads their description once, for the parse and for `--help`.
//!
//! - The asset paths: the two disks, each a directory or a FAT12 floppy image. Without them, the
//!   standalone build uses its built-in files. `--megadrive` adds the cartridge, for its tunes.
//! - `--saves`: the save directory, by default the per-user data directory. `--config`: the
//!   configuration directory, for the settings, by default the per-user configuration directory.
//!   `Providers.open` creates them if necessary. The agent keeps both in memory instead. The end
//!   of each host's help names the defaults (`writeStorageHelp`).
//! - `--data`: a data set directory. Without it, `Providers.open` extracts the data set in
//!   memory from the disks. With a data set, the game's films come from it (`GameFiles`).
//! - `--extract` with `--names` writes the data set and exits. `--scene` selects the first scene.
//!
//! The game gets a bound `AssetSource` and `Storage`. It does not know which kind of source it has.
const std = @import("std");
const builtin = @import("builtin");
const flashbackz = @import("flashbackz");
const platform = flashbackz.platform;
const DirectoryAssetSource = directory_mod.DirectoryAssetSource;
const DirectoryStorage = storage_mod.DirectoryStorage;
const Pack = flashbackz.asset_pack.Pack;
const directory_mod = @import("directory.zig");
const storage_mod = @import("storage.zig");
const data_set = @import("data_set.zig");
const clap = @import("clap.zig");
const extract = @import("extract");

/// The options that both hosts take; each host's description adds them to its own.
pub const shared_options = [_]clap.Option{
    .{
        .long = "scene",
        .value = "NAME",
        .help = "start in the title menu (menu) or directly in a level: jungle, city,\n" ++
            "tower, earth_city, spaceport, alien_surface or alien_base\n" ++
            "(default: the introduction)",
    },
    .{
        .long = "saves",
        .value = "DIR",
        .help = "where the saves are kept\n(default: the end of this help)",
    },
    .{
        .long = "config",
        .value = "DIR",
        .help = "where the settings are kept\n(default: the end of this help)",
    },
    .{
        .long = "data",
        .value = "DIR",
        .help = "read the data set from DIR, written by --extract\n" ++
            "(default: extracted from the disks at startup)",
    },
    .{
        .long = "extract",
        .value = "DIR",
        .help = "write the data set (characters, behaviors, messages) into DIR, a new or\n" ++
            "empty directory, and exit; it holds the game's content: keep it out of Git",
    },
    .{
        .long = "names",
        .value = "FILE",
        .help = "with --extract: the naming overlay to use instead of the built-in one",
    },
    .{
        .long = "megadrive",
        .value = "FILE",
        .help = "the Mega Drive edition's cartridge, Flashback (Europe) (En,Fr): its tunes\n" ++
            "play during play where it plays them (default: none, as in DOS)",
    },
};

/// The game's files: both floppy images, or directories extracted from them.
pub const assets: clap.Positional = .{
    .name = "ASSET_PATH",
    .help = "a floppy image (IMG/IMA) or extracted directory; give both disks",
    .min = 0,
    .max = 2,
};

/// The providers' options from a parse whose description includes `shared_options` and `assets`.
pub fn fromArgs(args: anytype, diagnostic: *clap.Diagnostic) clap.Error!Options {
    var result: Options = .{};
    if (args.value("scene")) |name| {
        result.entry = sceneEntry(name) orelse {
            diagnostic.* = .{ .argument = "--scene", .value = name };
            return error.InvalidValue;
        };
    }
    if (args.value("saves")) |dir| {
        result.saves = try nonEmpty("--saves", dir, diagnostic);
    }
    if (args.value("config")) |dir| {
        result.config = try nonEmpty("--config", dir, diagnostic);
    }
    if (args.value("data")) |dir| {
        result.data = try nonEmpty("--data", dir, diagnostic);
    }
    if (args.value("extract")) |dir| {
        result.extract = try nonEmpty("--extract", dir, diagnostic);
    }
    if (args.value("names")) |file| {
        result.names = try nonEmpty("--names", file, diagnostic);
    }
    if (args.value("megadrive")) |file| {
        result.megadrive = try nonEmpty("--megadrive", file, diagnostic);
    }
    for (args.positional("ASSET_PATH")) |path| {
        result.addAsset(path) catch {
            diagnostic.* = .{ .argument = "ASSET_PATH", .value = path };
            return error.InvalidValue;
        };
    }
    if (result.names != null and result.extract == null) {
        diagnostic.* = .{ .argument = "--names", .value = "--extract" };
        return error.NeedsOption;
    }
    if (result.extract != null) {
        // Extracting only writes the data set: the options of a game run do not apply.
        const Args = @TypeOf(args);
        for (args.given) |given| {
            if (given.option == Args.index("extract") or given.option == Args.index("names")) {
                continue;
            }
            diagnostic.* = .{ .argument = Args.flagName(given.option), .value = "--extract" };
            return error.ExcludedOption;
        }
    }
    return result;
}

/// `--extract`: writes the data set made from the options' disks, or the built-in ones, into the
/// chosen directory and prints the extraction report. Returns the exit status, after saying what
/// failed if anything.
pub fn extractCommand(
    gpa: std.mem.Allocator,
    io: std.Io,
    program: []const u8,
    options: Options,
) u8 {
    if (options.assets == null and options.built_in.disks.len == 0) {
        var buffer: [256]u8 = undefined;
        var stderr = std.Io.File.stderr().writerStreaming(io, &buffer);
        stderr.interface.print(
            "{s}: --extract needs the game's files: give both floppy images " ++
                "(disk1.img disk2.img) or a directory extracted from them\n",
            .{ program },
        ) catch {};
        stderr.interface.flush() catch {};
        return 2;
    }
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var providers: Providers = .empty;
    defer providers.deinit();
    const report = writeDataSet(gpa, arena, io, options, &providers) catch |err| {
        var buffer: [256]u8 = undefined;
        var stderr = std.Io.File.stderr().writerStreaming(io, &buffer);
        const out = &stderr.interface;
        const written = if (err == error.OutputNotEmpty)
            out.print("{s}: {s} must be a new or empty directory\n", .{
                program,
                options.extract.?,
            })
        else if (openError(err)) |failure| written: {
            out.print("{s}: ", .{ program }) catch {};
            break :written providers.writeFailure(failure, out);
        } else out.print("{s}: extraction failed: {s}\n", .{ program, @errorName(err) });
        written catch {};
        stderr.interface.flush() catch {};
        return 1;
    };
    var stdout = std.Io.File.stdout().writerStreaming(io, &.{});
    stdout.interface.writeAll(report) catch return 1;
    return 0;
}

/// `err` as one of the providers' errors, if it is one.
fn openError(err: anyerror) ?OpenError {
    inline for (@typeInfo(OpenError).error_set.error_names.?) |name| {
        if (err == @field(anyerror, name)) return @field(OpenError, name);
    }
    return null;
}

fn writeDataSet(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    options: Options,
    providers: *Providers,
) ![]const u8 {
    try providers.openAssets(gpa, io, options);
    providers.failed = .{ .what = "names file", .path = options.names orelse "" };
    const names: [:0]const u8 = if (options.names) |path|
        try readNames(io, arena, path)
    else
        extract.built_in_names;
    providers.failed = .{ .what = "data set directory", .path = options.extract.? };
    return data_set.writeDirectory(
        gpa,
        arena,
        io,
        providers.assetSource().?,
        names,
        options.extract.?,
    );
}

/// The `--names` file. Its read errors become the providers' own, which `writeFailure` shows
/// with the file's name.
fn readNames(io: std.Io, arena: std.mem.Allocator, path: []const u8) OpenError![:0]const u8 {
    const limit: std.Io.Limit = .limited(1 << 20);
    return std.Io.Dir.cwd().readFileAllocOptions(io, path, arena, limit, .of(u8), 0) catch |err|
        switch (err) {
            error.FileNotFound => error.NotFound,
            error.AccessDenied => error.AccessDenied,
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            else => error.Io,
        };
}

fn nonEmpty(
    comptime name: []const u8,
    value: []const u8,
    diagnostic: *clap.Diagnostic,
) clap.Error![]const u8 {
    if (value.len != 0) return value;
    diagnostic.* = .{ .argument = name, .value = value };
    return error.InvalidValue;
}

fn sceneEntry(value: []const u8) ?flashbackz.game.Entry {
    if (std.mem.eql(u8, value, "menu")) return .menu_development;
    const level = std.meta.stringToEnum(flashbackz.content.level.Id, value) orelse return null;
    return .{ .level_development = level };
}

pub const Options = struct {
    /// The game's files, each a floppy image or an extracted directory: usually the two disks.
    assets: ?[]const u8 = null,
    second_assets: ?[]const u8 = null,
    /// `--saves`: the save directory.
    saves: ?[]const u8 = null,
    /// `--config`: the configuration directory, for the settings.
    config: ?[]const u8 = null,
    /// `--data`: a data set directory, written by `--extract`.
    data: ?[]const u8 = null,
    /// `--extract`: write the data set here instead of running the game.
    extract: ?[]const u8 = null,
    /// `--names`: the naming overlay for `--extract`.
    names: ?[]const u8 = null,
    /// `--megadrive`: the Mega Drive edition's cartridge, for its tunes.
    megadrive: ?[]const u8 = null,
    /// The standalone build's files, read when no path names them.
    built_in: BuiltIn = .{},
    default_storage: DefaultStorage = .user_directories,
    entry: flashbackz.game.Entry = .automatic,

    pub fn addAsset(self: *Options, path: []const u8) error{ MissingValue, TooManyAssets }!void {
        if (path.len == 0) return error.MissingValue;
        if (self.assets == null) {
            self.assets = path;
        } else if (self.second_assets == null) {
            self.second_assets = path;
        } else {
            return error.TooManyAssets;
        }
    }
};

/// Where the game keeps its saves and its settings without `--saves` and `--config`: in the user's
/// directories, or in memory for the agent, whose runs touch no file they are not given.
pub const DefaultStorage = enum { user_directories, memory };

/// The standalone build's files (DESIGN.md 3): the disks, read when no asset path is given, and
/// the cartridge, read without `--megadrive`.
pub const BuiltIn = struct {
    disks: []const []const u8 = &.{},
    megadrive: ?[]const u8 = null,
};

/// The kind of asset source, for the host's start-up line and the agent's diagnostics.
pub const AssetKind = enum { none, directory, floppy, mixed, built_in };

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
    /// The `--data` directory is missing or unreadable.
    InvalidDataSet,
    /// The `--megadrive` file is not the accepted cartridge.
    UnsupportedCartridge,
};

/// The providers that a host owns while the game runs.
pub const Providers = struct {
    allocator: std.mem.Allocator = undefined,
    kind: AssetKind = .none,
    /// The save directory in use (owned).
    saves_path: []u8 = &.{},
    /// The configuration directory in use (owned).
    config_path: []u8 = &.{},
    content: ?Pack = null,
    saves: ?DirectoryStorage = null,
    config: ?DirectoryStorage = null,
    /// The data set, when original files are open: read from `--data` or extracted from them.
    data_arena: ?*std.heap.ArenaAllocator = null,
    data: ?flashbackz.behavior.data_set.Files = null,
    /// With a data set, the game's files: its films from the data set, the rest from `content`.
    game_files: ?flashbackz.film_files.GameFiles = null,
    /// What `open` or `openAssets` was opening when it failed, for `writeFailure`.
    failed: Failure = .{},

    pub const empty: Providers = .{};

    /// A path the user gave (borrowed from the options) and what it was for; no path for the
    /// default save directory or the disks' archives.
    pub const Failure = struct {
        what: []const u8 = "",
        path: []const u8 = "",
    };

    /// The user's message for a failed `open` or `openAssets`: what could not be opened and why,
    /// on one line ("cannot open the disk disk1.img: not found").
    pub fn writeFailure(
        self: *const Providers,
        err: OpenError,
        w: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        const why = switch (err) {
            error.NotFound => "not found",
            error.NotADirectory => "not a directory",
            error.InvalidImage => "not a floppy image of the game, nor a directory from one",
            error.ConflictingAsset => "a file differs from the other disk's (two editions?)",
            error.AccessDenied => "permission denied",
            error.NoApplicationDirectory => "no per-user directory here; give --saves DIR and " ++
                "--config DIR",
            error.Io => "read error",
            error.Canceled => "canceled",
            error.OutOfMemory => "out of memory",
            error.InvalidDataSet => "not a data set written by --extract",
            error.UnsupportedCartridge => "not the cartridge Flashback (Europe) (En,Fr)",
        };
        if (self.failed.path.len == 0) {
            try w.print("cannot open the {s}: {s}\n", .{ self.failed.what, why });
        } else {
            const failed = self.failed;
            try w.print("cannot open the {s} {s}: {s}\n", .{ failed.what, failed.path, why });
        }
    }

    /// Opens the providers that the options name, in this order:
    /// 1. the save and configuration directories, which it creates if necessary (not when the
    ///    agent keeps them in memory);
    /// 2. the asset source, from the asset paths or else the built-in disks;
    /// 3. the Mega Drive cartridge, from `--megadrive` or else the built-in one, if any;
    /// 4. the data set, from `--data` or else extracted from the disks.
    /// Without an asset path and built-in disks, it stops after step 1. Before each step, it sets
    /// `failed` to that step, for `writeFailure`. A failure releases every provider.
    pub fn open(
        self: *Providers,
        allocator: std.mem.Allocator,
        io: std.Io,
        environ: *const std.process.Environ.Map,
        options: Options,
    ) OpenError!void {
        self.allocator = allocator;
        errdefer self.deinit();
        if (options.saves != null or options.default_storage == .user_directories) {
            self.failed = .{ .what = "save directory", .path = options.saves orelse "" };
            self.saves_path = if (options.saves) |path|
                try allocator.dupe(u8, path)
            else
                try defaultSaveDirectory(allocator, environ);
            self.saves = try mapOpen(DirectoryStorage.open(allocator, io, self.saves_path, true));
        }
        if (options.config != null or options.default_storage == .user_directories) {
            self.failed = .{ .what = "configuration directory", .path = options.config orelse "" };
            self.config_path = if (options.config) |path|
                try allocator.dupe(u8, path)
            else
                try defaultConfigDirectory(allocator, environ);
            self.config = try mapOpen(DirectoryStorage.open(allocator, io, self.config_path, true));
        }
        if (options.assets == null and options.built_in.disks.len == 0) {
            self.failed = .{};
            return;
        }
        try self.importAssets(io, options);
        if (options.megadrive) |file| {
            self.failed = .{ .what = "Mega Drive cartridge", .path = file };
            try self.importCartridge(io, file);
        } else if (options.built_in.megadrive) |cartridge| {
            self.failed = .{ .what = "built-in Mega Drive cartridge" };
            try self.addCartridge(cartridge);
        }
        self.failed = .{ .what = "data set", .path = options.data orelse "" };
        try self.openDataSet(io, options.data);
        if (self.data) |*files| {
            self.game_files = .init(self.allocator, self.content.?.assetSource(), files);
        }
        self.failed = .{};
    }

    /// Adds the Mega Drive cartridge to the asset source, once it is known to be the accepted one.
    fn importCartridge(self: *Providers, io: std.Io, path: []const u8) OpenError!void {
        const megadrive = flashbackz.content.megadrive;
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            io,
            path,
            self.allocator,
            .limited(megadrive.size + 1),
        ) catch |err| return switch (err) {
            error.FileNotFound => error.NotFound,
            error.AccessDenied => error.AccessDenied,
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            else => error.UnsupportedCartridge,
        };
        defer self.allocator.free(bytes);
        try self.addCartridge(bytes);
    }

    fn addCartridge(self: *Providers, bytes: []const u8) OpenError!void {
        const megadrive = flashbackz.content.megadrive;
        if (!megadrive.isCartridge(bytes)) return error.UnsupportedCartridge;
        self.content.?.add(megadrive.asset, bytes) catch |err| return mapImportError(err);
    }

    /// Adds the files of a floppy image, given as bytes.
    fn importImage(self: *Providers, image: []const u8) OpenError!void {
        var imported = flashbackz.floppy.load(self.allocator, image) catch |err|
            return mapImportError(err);
        defer imported.deinit();
        self.content.?.merge(&imported) catch |err| return mapImportError(err);
    }

    /// Reads the data set from `directory`, or extracts it in memory from the original files.
    /// Without a directory, a failed extraction only leaves the data set out: scenes that do
    /// not need it still run.
    fn openDataSet(self: *Providers, io: std.Io, directory: ?[]const u8) OpenError!void {
        const arena = try self.allocator.create(std.heap.ArenaAllocator);
        arena.* = .init(self.allocator);
        self.data_arena = arena;
        if (directory) |path| {
            self.data = data_set.readDirectory(arena.allocator(), io, path) catch
                return error.InvalidDataSet;
        } else {
            self.data = data_set.extractInMemory(
                self.allocator,
                arena.allocator(),
                self.assetSource().?,
            ) catch |err| missing: {
                std.log.info("data set not extracted: {s}", .{ @errorName(err) });
                break :missing null;
            };
        }
    }

    /// Opens only the game's files (the asset paths, else the built-in disks), for tools that read
    /// the game and never save: `--extract` and the atlas. It opens no cartridge and no data set.
    pub fn openAssets(
        self: *Providers,
        allocator: std.mem.Allocator,
        io: std.Io,
        options: Options,
    ) OpenError!void {
        self.allocator = allocator;
        errdefer self.deinit();
        try self.importAssets(io, options);
    }

    /// Adds the files of the asset paths, or else of the built-in disks, to a new pack. Then it
    /// expands the archives of the disks in the pack.
    fn importAssets(self: *Providers, io: std.Io, options: Options) OpenError!void {
        self.content = Pack.init(self.allocator);
        if (options.assets) |path| {
            try self.importPath(io, path);
            if (options.second_assets) |second| {
                try self.importPath(io, second);
            }
        } else {
            self.failed = .{ .what = "built-in disks" };
            for (options.built_in.disks) |image| {
                try self.importImage(image);
            }
            self.kind = .built_in;
        }
        self.failed = .{ .what = "disks' archives" };
        flashbackz.content.archive.expandAll(&self.content.?) catch |err|
            return mapImportError(err);
        self.failed = .{};
    }

    fn importPath(self: *Providers, io: std.Io, path: []const u8) OpenError!void {
        self.failed = .{ .what = "disk", .path = path };
        const allocator = self.allocator;
        const kind: AssetKind = if (DirectoryAssetSource.open(
            allocator,
            io,
            path,
        )) |opened| directory: {
            var directory = opened;
            defer directory.deinit();
            const source = directory.assetSource();
            var listing = source.list("") catch return error.Io;
            defer listing.deinit();
            for (listing.names) |name| {
                // Refuse the superseded edition before reading large movies.
                if (platform.assetNameEql(name, "GAME_E.OVL")) return error.InvalidImage;
                var data = source.readAll(name, Pack.limit - self.content.?.total) catch
                    return error.InvalidImage;
                defer data.deinit();
                self.content.?.add(name, data.bytes) catch |err| return mapImportError(err);
            }
            break :directory .directory;
        } else |err| image: {
            if (err != error.NotADirectory) return err;
            const image_bytes = std.Io.Dir.cwd().readFileAlloc(
                io,
                path,
                allocator,
                .limited(4 * 1024 * 1024),
            ) catch return error.InvalidImage;
            defer allocator.free(image_bytes);
            try self.importImage(image_bytes);
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
        if (self.game_files) |*files| {
            files.deinit();
        }
        if (self.data_arena) |arena| {
            arena.deinit();
            self.allocator.destroy(arena);
        }
        if (self.content) |*content| {
            content.deinit();
        }
        if (self.saves) |*s| {
            s.deinit();
        }
        if (self.config) |*s| {
            s.deinit();
        }
        self.allocator.free(self.saves_path);
        self.allocator.free(self.config_path);
        self.* = .{ .failed = self.failed };
    }

    /// The bound asset source: with a data set, the game's files (the films from the data set),
    /// else the original's files. Null when the options give no asset path and the build has no
    /// built-in disks: then `open` opens only the save directory.
    pub fn assetSource(self: *Providers) ?platform.AssetSource {
        if (self.game_files) |*files| return files.assetSource();
        return if (self.content) |*content| content.assetSource() else null;
    }

    /// The save directory's storage; null when the saves stay in memory.
    pub fn savesStorage(self: *Providers) ?platform.Storage {
        return if (self.saves) |*saves| saves.storage() else null;
    }

    /// The configuration directory's storage; null when the settings stay in memory.
    pub fn configStorage(self: *Providers) ?platform.Storage {
        return if (self.config) |*config| config.storage() else null;
    }

    pub fn dataSet(self: *const Providers) ?*const flashbackz.behavior.data_set.Files {
        return if (self.data) |*files| files else null;
    }
};

/// The per-user directory of the saves: `$XDG_DATA_HOME/flashbackz/saves`, else
/// `$HOME/.local/share/flashbackz/saves`, and `%APPDATA%\flashbackz\saves` on Windows. The caller
/// owns the result.
pub fn defaultSaveDirectory(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) error{ NoApplicationDirectory, OutOfMemory }![]u8 {
    return userDirectory(allocator, environ, save_directory);
}

/// The per-user configuration directory, for the settings: `$XDG_CONFIG_HOME/flashbackz`, else
/// `$HOME/.config/flashbackz`, and `%APPDATA%\flashbackz` on Windows. The caller owns the result.
pub fn defaultConfigDirectory(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) error{ NoApplicationDirectory, OutOfMemory }![]u8 {
    return userDirectory(allocator, environ, config_directory);
}

/// Where a per-user directory is, by the platform's conventions.
const UserDirectory = struct {
    /// The path below `%APPDATA%`, on Windows.
    windows: []const u8,
    /// Elsewhere, the XDG variable that gives the base, and the base below `$HOME` without it.
    xdg_variable: []const u8,
    home_base: []const u8,
    /// The path below the base.
    below: []const u8,
};

const save_directory: UserDirectory = .{
    .windows = "flashbackz\\saves",
    .xdg_variable = "XDG_DATA_HOME",
    .home_base = ".local/share",
    .below = "flashbackz/saves",
};

const config_directory: UserDirectory = .{
    .windows = "flashbackz",
    .xdg_variable = "XDG_CONFIG_HOME",
    .home_base = ".config",
    .below = "flashbackz",
};

fn userDirectory(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    comptime place: UserDirectory,
) error{ NoApplicationDirectory, OutOfMemory }![]u8 {
    if (builtin.os.tag == .windows) {
        const appdata = variable(environ, "APPDATA") orelse return error.NoApplicationDirectory;
        return std.fmt.allocPrint(allocator, "{s}\\" ++ place.windows, .{ appdata });
    }
    if (variable(environ, place.xdg_variable)) |base| {
        return std.fmt.allocPrint(allocator, "{s}/" ++ place.below, .{ base });
    }
    const home = variable(environ, "HOME") orelse return error.NoApplicationDirectory;
    return std.fmt.allocPrint(allocator, "{s}/" ++ place.home_base ++ "/" ++ place.below, .{
        home,
    });
}

/// The value of an environment variable that is set and not empty.
fn variable(environ: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const value = environ.get(name) orelse return null;
    return if (value.len == 0) null else value;
}

/// The end of a host's help: where the saves and the settings go without `--saves` and
/// `--config`. The user's directories come from this run's environment, as `Providers.open`
/// makes them.
pub fn writeStorageHelp(
    w: *std.Io.Writer,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    default_storage: DefaultStorage,
) (std.Io.Writer.Error || error{ OutOfMemory })!void {
    try w.writeAll("\nWithout --saves and --config:\n");
    if (default_storage == .memory) {
        return w.writeAll("  the saves and the settings stay in memory, for this run only\n");
    }
    try writeDefault(w, allocator, environ, "saves     ", save_directory, "", "--saves");
    const settings_file = std.fs.path.sep_str ++ flashbackz.settings.record_name;
    try writeDefault(
        w,
        allocator,
        environ,
        "settings  ",
        config_directory,
        settings_file,
        "--config",
    );
}

/// One line of `writeStorageHelp`: the label, then the directory and `file`, or the option to
/// give when the environment names no directory.
fn writeDefault(
    w: *std.Io.Writer,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    comptime label: []const u8,
    comptime place: UserDirectory,
    comptime file: []const u8,
    comptime option: []const u8,
) (std.Io.Writer.Error || error{ OutOfMemory })!void {
    const directory = userDirectory(allocator, environ, place) catch |err| switch (err) {
        error.NoApplicationDirectory => {
            return w.writeAll(
                "  " ++ label ++ "no per-user directory here: give " ++ option ++ " DIR\n",
            );
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer allocator.free(directory);
    try w.print("  " ++ label ++ "{s}" ++ file ++ "\n", .{ directory });
}

const contract = @import("contract.zig");

fn testEnviron(
    allocator: std.mem.Allocator,
    pairs: []const [2][]const u8,
) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(allocator);
    for (pairs) |pair| {
        try map.put(pair[0], pair[1]);
    }
    return map;
}

test "the save directory follows the platform's application data convention" {
    const allocator = std.testing.allocator;
    {
        var env = try testEnviron(allocator, &.{.{ "XDG_DATA_HOME", "/data" }});
        defer env.deinit();
        if (builtin.os.tag == .windows) {
            // Windows reads %APPDATA% only.
            try std.testing.expectError(
                error.NoApplicationDirectory,
                defaultSaveDirectory(allocator, &env),
            );
        } else {
            const path = try defaultSaveDirectory(allocator, &env);
            defer allocator.free(path);
            try std.testing.expectEqualStrings("/data/flashbackz/saves", path);
        }
    }
    {
        var env = try testEnviron(
            allocator,
            &.{.{ "HOME", "/home/player" }, .{ "APPDATA", "C:\\Users\\player\\AppData\\Roaming" }},
        );
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
        try std.testing.expectError(
            error.NoApplicationDirectory,
            defaultSaveDirectory(allocator, &env),
        );
    }
}

test "the configuration directory follows the platform's conventions" {
    const allocator = std.testing.allocator;
    {
        var env = try testEnviron(allocator, &.{.{ "XDG_CONFIG_HOME", "/config" }});
        defer env.deinit();
        if (builtin.os.tag == .windows) {
            try std.testing.expectError(
                error.NoApplicationDirectory,
                defaultConfigDirectory(allocator, &env),
            );
        } else {
            const path = try defaultConfigDirectory(allocator, &env);
            defer allocator.free(path);
            try std.testing.expectEqualStrings("/config/flashbackz", path);
        }
    }
    {
        var env = try testEnviron(
            allocator,
            &.{.{ "HOME", "/home/player" }, .{ "APPDATA", "C:\\Users\\player\\AppData\\Roaming" }},
        );
        defer env.deinit();
        const path = try defaultConfigDirectory(allocator, &env);
        defer allocator.free(path);
        const want = if (builtin.os.tag == .windows)
            "C:\\Users\\player\\AppData\\Roaming\\flashbackz"
        else
            "/home/player/.config/flashbackz";
        try std.testing.expectEqualStrings(want, path);
    }
}

test "the help names the save and configuration directories of this run" {
    const allocator = std.testing.allocator;
    var buf: [512]u8 = undefined;
    {
        var w: std.Io.Writer = .fixed(&buf);
        var env = try testEnviron(
            allocator,
            &.{.{ "HOME", "/home/player" }, .{ "APPDATA", "C:\\Users\\player\\AppData\\Roaming" }},
        );
        defer env.deinit();
        try writeStorageHelp(&w, allocator, &env, .user_directories);
        const want = if (builtin.os.tag == .windows)
            "  saves     C:\\Users\\player\\AppData\\Roaming\\flashbackz\\saves\n" ++
                "  settings  C:\\Users\\player\\AppData\\Roaming\\flashbackz\\settings.zon\n"
        else
            "  saves     /home/player/.local/share/flashbackz/saves\n" ++
                "  settings  /home/player/.config/flashbackz/settings.zon\n";
        try std.testing.expectEqualStrings(
            "\nWithout --saves and --config:\n" ++ want,
            w.buffered(),
        );
    }
    {
        var w: std.Io.Writer = .fixed(&buf);
        var env = try testEnviron(allocator, &.{});
        defer env.deinit();
        try writeStorageHelp(&w, allocator, &env, .user_directories);
        try std.testing.expectEqualStrings(
            "\nWithout --saves and --config:\n" ++
                "  saves     no per-user directory here: give --saves DIR\n" ++
                "  settings  no per-user directory here: give --config DIR\n",
            w.buffered(),
        );
    }
    {
        var w: std.Io.Writer = .fixed(&buf);
        var env = try testEnviron(allocator, &.{});
        defer env.deinit();
        try writeStorageHelp(&w, allocator, &env, .memory);
        try std.testing.expect(
            std.mem.endsWith(u8, w.buffered(), "stay in memory, for this run only\n"),
        );
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
    try directory_mod.writeFixture(io, game_dir);

    var env = try testEnviron(allocator, &.{.{ "XDG_DATA_HOME", "/unused" }});
    defer env.deinit();
    var paths: [3][]u8 = undefined;
    inline for (.{ "game", "saves", "config" }, 0..) |sub, i| {
        paths[i] = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, sub });
    }
    defer for (paths) |p| allocator.free(p);

    // A game directory: the asset source passes the contract, and each storage keeps a record.
    {
        var providers: Providers = .empty;
        const options: Options = .{ .assets = paths[0], .saves = paths[1], .config = paths[2] };
        try providers.open(allocator, io, &env, options);
        defer providers.deinit();
        try std.testing.expect(providers.kind != .none);
        try contract.assetContract(providers.assetSource().?);
        const config = providers.configStorage().?;
        try config.save("settings.zon", ".{}");
        var settings = try config.load("settings.zon");
        defer settings.deinit();
        try std.testing.expectEqualStrings(".{}", settings.bytes);
        const s = providers.savesStorage().?;
        try s.save("CLI.PT", "position");
        var loaded = try s.load("CLI.PT");
        defer loaded.deinit();
        try std.testing.expectEqualStrings("position", loaded.bytes);
        try s.deleteSave("CLI.PT");
    }

    // Without an asset path, only the storage opens, and `open` creates its directories.
    {
        var providers: Providers = .empty;
        try providers.open(allocator, io, &env, .{ .saves = paths[1], .config = paths[2] });
        defer providers.deinit();
        try std.testing.expectEqual(AssetKind.none, providers.kind);
        try std.testing.expect(providers.assetSource() == null);
        var names = try providers.savesStorage().?.listSaves();
        names.deinit();
        try std.testing.expectEqualStrings(paths[1], providers.saves_path);
        try std.testing.expectEqualStrings(paths[2], providers.config_path);
    }

    // A path that is missing, or not a directory.
    {
        var providers: Providers = .empty;
        const missing = try std.fmt.allocPrint(allocator, "{s}/absent", .{ base });
        defer allocator.free(missing);
        const options: Options = .{ .assets = missing, .saves = paths[1], .config = paths[2] };
        const failed = providers.open(allocator, io, &env, options);
        try std.testing.expectError(error.NotFound, failed);
        var message: std.Io.Writer.Allocating = .init(allocator);
        defer message.deinit();
        try providers.writeFailure(error.NotFound, &message.writer);
        const expected = try std.fmt.allocPrint(
            allocator,
            "cannot open the disk {s}: not found\n",
            .{ missing },
        );
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, message.written());
        const not_a_directory = try std.fmt.allocPrint(allocator, "{s}/game/game.cfg", .{ base });
        defer allocator.free(not_a_directory);
        try std.testing.expectError(
            error.InvalidImage,
            providers.open(allocator, io, &env, .{
                .assets = not_a_directory,
                .saves = paths[1],
                .config = paths[2],
            }),
        );
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
    const saves = try std.fmt.allocPrint(allocator, "{s}/saves", .{ base });
    defer allocator.free(saves);
    const path = try std.fmt.allocPrint(allocator, "{s}/game.ima", .{ base });
    defer allocator.free(path);
    var providers: Providers = .empty;
    try providers.open(allocator, io, &env, .{
        .assets = path,
        .saves = saves,
        .default_storage = .memory,
    });
    defer providers.deinit();
    try std.testing.expectEqual(AssetKind.floppy, providers.kind);
    var content = try providers.assetSource().?.readAll("data/file.dat", 600);
    defer content.deinit();
    try std.testing.expectEqual(@as(usize, 600), content.bytes.len);
}

test "the standalone build's files stand in for paths, which still take precedence" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const image = try flashbackz.floppy.testImage(allocator);
    defer allocator.free(image);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = path_buffer[0..try tmp.dir.realPath(io, &path_buffer)];
    const saves = try std.fmt.allocPrint(allocator, "{s}/saves", .{ base });
    defer allocator.free(saves);
    const missing = try std.fmt.allocPrint(allocator, "{s}/absent.img", .{ base });
    defer allocator.free(missing);
    var env = try testEnviron(allocator, &.{});
    defer env.deinit();
    const disks: []const []const u8 = &.{ image };
    {
        var providers: Providers = .empty;
        defer providers.deinit();
        const options: Options = .{
            .saves = saves,
            .default_storage = .memory,
            .built_in = .{ .disks = disks },
        };
        try providers.open(allocator, io, &env, options);
        try std.testing.expectEqual(AssetKind.built_in, providers.kind);
        var content = try providers.assetSource().?.readAll("data/file.dat", 600);
        defer content.deinit();
        try std.testing.expectEqual(@as(usize, 600), content.bytes.len);
    }
    // A built-in cartridge that is not the accepted one is refused, as a --megadrive file is.
    {
        var providers: Providers = .empty;
        const options: Options = .{
            .saves = saves,
            .default_storage = .memory,
            .built_in = .{ .disks = disks, .megadrive = "not a cartridge" },
        };
        const failed = providers.open(allocator, io, &env, options);
        try std.testing.expectError(error.UnsupportedCartridge, failed);
        var message: std.Io.Writer.Allocating = .init(allocator);
        defer message.deinit();
        try providers.writeFailure(error.UnsupportedCartridge, &message.writer);
        try std.testing.expectEqualStrings(
            "cannot open the built-in Mega Drive cartridge: " ++
                "not the cartridge Flashback (Europe) (En,Fr)\n",
            message.written(),
        );
    }
    // A path on the command line wins over the built-in disks, even a missing one.
    {
        var providers: Providers = .empty;
        const options: Options = .{
            .assets = missing,
            .saves = saves,
            .default_storage = .memory,
            .built_in = .{ .disks = disks },
        };
        try std.testing.expectError(error.NotFound, providers.open(allocator, io, &env, options));
    }
}

test "multiple disks merge files and conflicting editions fail without partial providers" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const image = try flashbackz.floppy.testImage(allocator);
    defer allocator.free(image);
    try tmp.dir.writeFile(io, .{ .sub_path = "first.img", .data = image });
    @memcpy(image[33 * 512..][0..11], "SECOND  DAT");
    try tmp.dir.writeFile(io, .{ .sub_path = "second.img", .data = image });
    @memcpy(image[33 * 512..][0..11], "FILE    DAT");
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
    var options: Options = .{ .saves = paths[3], .default_storage = .memory };
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
    var conflicting: Options = .{ .saves = paths[3], .default_storage = .memory };
    try conflicting.addAsset(paths[0]);
    try conflicting.addAsset(paths[2]);
    var failed: Providers = .empty;
    try std.testing.expectError(
        error.ConflictingAsset,
        failed.open(allocator, io, &env, conflicting),
    );
    try std.testing.expect(failed.content == null and failed.saves == null);
    // The game's files are the two disks: a third path is refused.
    try std.testing.expectError(error.TooManyAssets, options.addAsset("third.img"));
    // A --megadrive file that is not the accepted cartridge is refused, leaving no provider.
    var cartridge: Options = .{
        .saves = paths[3],
        .default_storage = .memory,
        .megadrive = paths[1],
    };
    try cartridge.addAsset(paths[0]);
    try std.testing.expectError(
        error.UnsupportedCartridge,
        failed.open(allocator, io, &env, cartridge),
    );
    try std.testing.expect(failed.content == null and failed.saves == null);
}
