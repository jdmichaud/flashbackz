//! The interactive host: the outer loop of the SDL targets, Linux and Windows (DESIGN.md).
//!
//! It owns the backend, the asset and storage providers and the game. It decides when the next
//! update runs; the game decides what happens in an update. The display paces the presentation when
//! the renderer presents in step with it; else a sleep at `fallback_hz` paces it.
//!
//! Information goes to standard error. Standard output carries only the `--event-log` lines.
const std = @import("std");
const flashbackz = @import("flashbackz");
const native = @import("native");
const c = @import("c");
const version = @import("root.zig");
const SdlBackend = backend_mod.SdlBackend;
const backend_mod = @import("backend.zig");
const clap = native.clap;

/// The rate of the fallback pacer, when the display does not pace the presentation.
pub const fallback_hz: u32 = 60;

/// Whether the executable refuses to start without an asset path. The placeholder game
/// runs without files; a port whose game needs the original's files sets this to true.
pub const assets_required = false;

const program_name = "flashbackz-sdl";

/// The command line, described once for parsing and for `--help`.
pub const Args = clap.Parser(.{
    .name = program_name,
    .description = "Flashback, played from the original floppy disks.",
    .options = &(native.cli.shared_options ++ [_]clap.Option{
        .{ .long = "scale", .value = "N", .help = "window scale, 1 to 64 (default 3)" },
        .{ .long = "no-vsync", .help = "do not ask for display-paced presentation" },
        .{ .long = "software", .help = "force SDL's software renderer" },
        .{
            .long = "event-log",
            .value = "SECONDS",
            .help = "write every polled event to standard output as one JSON line, and quit\n" ++
                "after that many seconds",
        },
        .{ .long = "run-for", .value = "SECONDS", .help = "quit after that many seconds, without the event log" },
        .{ .long = "fps", .value = "N", .help = "the fallback pacer's rate, 1 to 1000 (default 60)" },
    }),
    .positionals = &.{native.cli.assets},
});

pub const Options = struct {
    help: bool = false,
    scale: ?u32 = null,
    /// `--no-vsync` sets it to false.
    vsync: ?bool = null,
    software: bool = false,
    /// When set, the run stops after this many nanoseconds, and the host logs every event.
    event_log_ns: ?u64 = null,
    /// `--run-for`: stop after this many nanoseconds, without an event log.
    run_for_ns: ?u64 = null,
    /// `--fps`: the rate of the fallback pacer. It changes only the pacing, never the game.
    fps: ?u32 = null,
    /// The sources of the game's assets and saves.
    providers: native.cli.Options = .{},

    /// The time at which the run ends by itself: the nearer of the given deadlines, or null.
    pub fn deadlineNs(self: Options) ?u64 {
        if (self.event_log_ns) |ns| {
            if (self.run_for_ns) |other| return @min(ns, other);
            return ns;
        }
        return self.run_for_ns;
    }
};

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    options: Options,
) !u8 {
    var err_buf: [1024]u8 = undefined;
    var err_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
    const err = &err_writer.interface;
    const name = program_name;

    var ver_buf: [32]u8 = undefined;
    const check = version.checkVersion(&ver_buf);
    try err.print("{s}: SDL2 {s} linked (pinned {s})\n", .{ name, check.linked, check.pinned });
    try err.flush();

    // The providers: the save directory, and the game directory of the positional argument. They
    // outlive the game and the backend, which only borrow their interfaces.
    var providers: native.cli.Providers = .empty;
    defer providers.deinit();
    providers.open(gpa, io, environ, options.providers) catch |e| {
        std.log.err("cannot open the providers: {s}", .{@errorName(e)});
        return 1;
    };
    try err.print(
        "{s}: assets: {s}, saves: {s}\n",
        .{ name, @tagName(providers.kind), providers.saves_path },
    );
    try err.flush();

    // The backend is made before the game and released after it.
    defer c.SDL_Quit();
    var backend = try SdlBackend.init(gpa, .{
        .title = "flashbackz — platform smoke",
        .initial_window_scale = options.scale orelse 3,
        .prefer_vsync = options.vsync orelse true,
    });
    defer backend.deinit();
    backend.force_software_renderer = options.software;

    var out_buf: [64 * 1024]u8 = undefined;
    var out_writer = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &out_writer.interface;
    defer out.flush() catch {};
    if (options.event_log_ns != null) backend.event_log = out;

    var game = flashbackz.Game.initWithEntry(
        gpa,
        providers.assetSource(),
        providers.storage(),
        providers.dataSet(),
        options.providers.entry,
    ) catch |e| {
        if (e == error.NotFound) {
            std.log.err(
                "a required game resource is missing; supply both disk1.img and disk2.img, or a complete extracted directory",
                .{},
            );
        } else std.log.err("cannot load game: {s}", .{@errorName(e)});
        return 1;
    };
    defer game.deinit();

    var p = backend.asPlatform();
    var pacer: Pacer = .{ .period_ns = std.time.ns_per_s / (options.fps orelse fallback_hz) };
    var deadline_ns: ?u64 = null;
    const deadline_limit = options.deadlineNs();
    var announced_first_frame = false;
    const start_ns = p.nowNs();
    while (true) {
        const frames_before = game.frames_presented;
        const result = game.update(&p) catch |e| {
            std.log.err("game update failed: {s}", .{@errorName(e)});
            try out.flush();
            return 1;
        };
        // A window that never painted looks the same as a window whose frames do not reach the
        // display. The renderer's name and the first frame tell them apart.
        if (!announced_first_frame and game.frames_presented > 0) {
            if (game.sceneKind() == .menu or game.sceneKind() == .level) {
                c.SDL_SetWindowTitle(backend.window.?, "flashbackz");
            }
            announced_first_frame = true;
            const size = backend.window_size;
            try err.print("{s}: first frame after {d}ms in a {d}x{d} window, renderer {s}{s}\n", .{
                name,
                (p.nowNs() - start_ns) / std.time.ns_per_ms,
                size.width,
                size.height,
                if (backend.rendererName().len != 0) backend.rendererName() else "unknown",
                if (backend.vsync) ", display-paced" else "",
            });
            try err.flush();
        }
        if (backend.event_log != null) try out.flush();
        if (result == .finished) break;
        const now = p.nowNs();
        if (deadline_limit) |limit| {
            // The deadline starts when the platform is up, so a slow start does not use log time.
            if (deadline_ns == null and backend.started) deadline_ns = now + limit;
            if (deadline_ns) |d| if (now >= d) break;
        }
        // The display paces an iteration only if the iteration presented a frame.
        if (game.needsCatchup(now)) continue;
        pacer.wait(now, backend.vsync and game.frames_presented != frames_before);
    }

    const audio = p.audioStatus();
    try err.print("{s}: {d} updates, {d} frames presented, {d} events consumed, paced by {s}\n", .{
        name,
        game.update_count,
        game.frames_presented,
        game.events_consumed,
        if (backend.vsync) "the display" else "the fallback clock",
    });
    try err.print(
        "{s}: audio {s}, {d} frames played, {d} still queued\n",
        .{
            name,
            if (audio.running) "open" else "closed",
            audio.played_frames,
            audio.queued_frames,
        },
    );
    try err.flush();
    try out.flush();
    return 0;
}

/// Keeps the fallback rate. A long update does not cause a burst of short frames after it.
pub const Pacer = struct {
    period_ns: u64 = std.time.ns_per_s / fallback_hz,
    next_ns: u64 = 0,

    /// `vsync` tells that the display paced this iteration, which is true only if the iteration
    /// presented a frame. Otherwise the clock paces it, so a loop that draws nothing does not spin.
    pub fn wait(self: *Pacer, now_ns: u64, vsync: bool) void {
        if (vsync) {
            self.next_ns = 0;
            return;
        }
        // Keep the ideal grid, so the next sleep makes up for a sleep that overran. Only an update
        // more than one full period late resynchronises, so no burst of instant frames follows.
        if (self.next_ns == 0 or now_ns > self.next_ns + self.period_ns) self.next_ns = now_ns;
        self.next_ns += self.period_ns;
        if (self.next_ns <= now_ns) return;
        const ms = (self.next_ns - now_ns) / std.time.ns_per_ms;
        if (ms > 0) c.SDL_Delay(@intCast(ms));
    }
};

pub const ArgError = clap.Error || error{MissingAssets};

/// Parses `args`, the arguments after the program's name; the options point into them.
pub fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8, diagnostic: *clap.Diagnostic) ArgError!Options {
    var parsed = try Args.parse(allocator, args, diagnostic);
    defer parsed.deinit(allocator);
    if (parsed.help) return .{ .help = true };
    const options: Options = .{
        .scale = try parsed.number(u32, "scale", 1, SdlBackend.max_window_scale, diagnostic),
        .vsync = if (parsed.flag("no-vsync")) false else null,
        .software = parsed.flag("software"),
        .event_log_ns = try seconds(parsed, "event-log", diagnostic),
        .run_for_ns = try seconds(parsed, "run-for", diagnostic),
        .fps = try parsed.number(u32, "fps", 1, 1000, diagnostic),
        .providers = try native.cli.fromArgs(parsed, diagnostic),
    };
    if ((assets_required or options.providers.entry == .level_development) and
        options.providers.assets == null) return error.MissingAssets;
    return options;
}

/// A positive number of seconds, at most a day, in nanoseconds.
fn seconds(parsed: Args, comptime long: []const u8, diagnostic: *clap.Diagnostic) clap.Error!?u64 {
    const s = try parsed.number(f64, long, std.math.floatMin(f64), 86_400, diagnostic) orelse return null;
    return @intFromFloat(s * std.time.ns_per_s);
}

fn testParse(args: []const []const u8) ArgError!Options {
    var diagnostic: clap.Diagnostic = .{};
    return parseArgs(std.testing.allocator, args, &diagnostic);
}

test "the host options are parsed, bounded and defaulted" {
    const defaults = try testParse(&.{});
    try std.testing.expectEqual(@as(?u32, null), defaults.scale);
    try std.testing.expectEqual(@as(?bool, null), defaults.vsync);
    try std.testing.expectEqual(@as(?u64, null), defaults.deadlineNs());

    const all = try testParse(&.{
        "--scale",
        "2",
        "--no-vsync",
        "--software",
        "--event-log",
        "1.5",
        "--run-for",
        "1",
        "game",
        "--saves",
        "saves",
    });
    try std.testing.expectEqual(@as(?u32, 2), all.scale);
    try std.testing.expectEqual(@as(?bool, false), all.vsync);
    try std.testing.expect(all.software);
    try std.testing.expectEqual(@as(?u64, 1_000_000_000), all.deadlineNs());
    try std.testing.expectEqualStrings("game", all.providers.assets.?);
    try std.testing.expectEqualStrings("saves", all.providers.saves.?);

    for ([_][]const []const u8{
        &.{ "--scale", "0" },
        &.{ "--scale", "99999" },
        &.{ "--event-log", "-1" },
        &.{ "--event-log", "0" },
        &.{ "--fps", "0" },
        &.{ "--scene", "unknown", "game" },
        &.{ "--data", "" },
    }) |args| try std.testing.expectError(error.InvalidValue, testParse(args));
    try std.testing.expectError(error.UnknownOption, testParse(&.{"--frobnicate"}));
    try std.testing.expectError(error.MissingAssets, testParse(&.{ "--scene", "jungle" }));
    try std.testing.expect((try testParse(&.{ "--scale", "2", "--help" })).help);
    const data = try testParse(&.{ "--data", "set", "disk1.img" });
    try std.testing.expectEqualStrings("set", data.providers.data.?);
    const disks = try testParse(&.{
        "disk1.img",
        "disk2.img",
    });
    try std.testing.expectEqualStrings("disk1.img", disks.providers.assets.?);
    try std.testing.expectEqualStrings("disk2.img", disks.providers.second_assets.?);
    try std.testing.expectError(error.TooManyArguments, testParse(&.{ "disk1.img", "disk2.img", "disk3.img" }));
    const jungle_options = try testParse(&.{
        "--scene",
        "jungle",
        "game.ima",
    });
    try std.testing.expectEqual(
        flashbackz.game.Entry{ .level_development = .jungle },
        jungle_options.providers.entry,
    );
}

test "the fallback pacer holds its period without accumulating debt" {
    var pacer: Pacer = .{};
    pacer.wait(0, true);
    try std.testing.expectEqual(@as(u64, 0), pacer.next_ns);
    pacer.wait(0, false);
    try std.testing.expectEqual(pacer.period_ns, pacer.next_ns);
    pacer.wait(pacer.period_ns, false);
    try std.testing.expectEqual(@as(u64, 2 * (std.time.ns_per_s / fallback_hz)), pacer.next_ns);
    pacer.wait(10 * std.time.ns_per_s, false);
    try std.testing.expectEqual(@as(u64, 10 * std.time.ns_per_s) + pacer.period_ns, pacer.next_ns);
}
