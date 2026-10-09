//! flashbackz-extract: convert the user's game files into the readable data set (DESIGN.md
//! section 3). Images and sound are not extracted; the game reads them from the originals.
const std = @import("std");
const native = @import("native");
const extract = @import("extract");

const clap = native.clap;

/// The command line, described once for parsing and for `--help`.
const Args = clap.Parser(.{
    .name = "flashbackz-extract",
    .description = "Converts the user's game files into the readable data set: characters, behavior\n" ++
        "tables and messages. Images and sound are not extracted.",
    .options = &.{
        .{ .long = "names", .value = "FILE", .help = "naming overlay to use instead of the built-in one" },
    },
    .positionals = &.{
        .{ .name = "OUTPUT_DIRECTORY", .help = "a new or empty directory, outside any Git repository" },
        .{
            .name = "ASSET_PATH",
            .help = "a floppy image (IMG/IMA) or extracted directory; give both disks",
            .max = 8,
        },
    },
});

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var diagnostic: clap.Diagnostic = .{};
    const args = Args.parse(arena, try clap.processArguments(arena, init.minimal.args), &diagnostic) catch |err| {
        var buf: [1024]u8 = undefined;
        var w = std.Io.File.stderr().writerStreaming(io, &buf);
        try Args.writeError(&w.interface, err, diagnostic);
        try w.interface.flush();
        std.process.exit(2);
    };
    if (args.help) {
        var buf: [2048]u8 = undefined;
        var w = std.Io.File.stdout().writerStreaming(io, &buf);
        try Args.writeHelp(&w.interface);
        return w.interface.flush();
    }
    const names_path = args.value("names");
    const output = args.positional("OUTPUT_DIRECTORY")[0];
    const assets = args.positional("ASSET_PATH");

    const names_source: [:0]const u8 = if (names_path) |path|
        try std.Io.Dir.cwd().readFileAllocOptions(
            io,
            path,
            arena,
            .limited(1024 * 1024),
            .of(u8),
            0,
        )
    else
        extract.built_in_names;

    var providers: native.Providers = .empty;
    defer providers.deinit();
    try providers.openAssets(gpa, io, assets);
    const source = providers.assetSource().?;

    try std.Io.Dir.cwd().createDirPath(io, output);
    var out_dir = try std.Io.Dir.cwd().openDir(io, output, .{ .iterate = true });
    defer out_dir.close(io);
    var entries = out_dir.iterate();
    if (try entries.next(io) != null) return fail(
        io,
        "the output directory must be new or empty\n",
    );
    var files: Files = .{ .dir = out_dir, .io = io };
    _ = try extract.extractAll(gpa, arena, source, names_source, .{
        .context = &files,
        .put = Files.put,
    });
    const summary = try out_dir.readFileAlloc(io, "report.txt", arena, .limited(1 << 20));
    var stdout = std.Io.File.stdout().writerStreaming(io, &.{});
    try stdout.interface.writeAll(summary);
}

const Files = struct {
    dir: std.Io.Dir,
    io: std.Io,
    fn put(context: *anyopaque, path: []const u8, bytes: []const u8) anyerror!void {
        const self: *Files = @ptrCast(@alignCast(context));
        if (std.fs.path.dirname(path)) |parent| try self.dir.createDirPath(self.io, parent);
        try self.dir.writeFile(self.io, .{ .sub_path = path, .data = bytes });
    }
};

fn fail(io: std.Io, message: []const u8) !void {
    var stderr = std.Io.File.stderr().writerStreaming(io, &.{});
    try stderr.interface.writeAll(message);
    std.process.exit(2);
}
