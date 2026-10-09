//! flashbackz-agent: the headless host. It runs the game on the agent backend for a number of frames,
//! at a fixed 60 Hz clock, presses keys at the frames it is told, and prints one JSON line with the
//! counts and the hashes of the state and of the last frame. Two runs with the same arguments print
//! the same line on every machine; a port builds its scripted tests and its debugging on this.
//!
//! With an asset path, the game reads that directory; with `--saves`, it saves there. Without them,
//! it runs on in-memory providers, so the run touches no file.
const std = @import("std");
const flashbackz = @import("flashbackz");
const agent = @import("agent");
const native = @import("native");
const clap = native.clap;

/// The command line, described once for parsing and for `--help`.
const Args = clap.Parser(.{
    .name = "flashbackz-agent",
    .description = "The headless host: runs the game for a number of frames at a fixed 60 Hz clock, presses\n" ++
        "the keys it is told and prints the state and frame hashes as JSON lines.",
    .options = &(native.cli.shared_options ++ [_]clap.Option{
        .{ .long = "frames", .value = "N", .help = "run N host frames (default 120)" },
        .{
            .long = "key",
            .value = "F:KEY",
            .repeats = true,
            .help = "tap KEY (a platform.Key, as f2 or left) at host frame F",
        },
        .{ .long = "key-down", .value = "F:KEY", .repeats = true, .help = "hold KEY from host frame F" },
        .{ .long = "key-up", .value = "F:KEY", .repeats = true, .help = "release KEY at host frame F" },
        .{
            .long = "key-repeat",
            .value = "F:KEY",
            .repeats = true,
            .help = "the keyboard repeats the held KEY at host frame F",
        },
        .{
            .long = "button-down",
            .value = "F:BUTTON",
            .repeats = true,
            .help = "press a gamepad button (a platform.ControllerButton, as a or\n" ++
                "dpad_left) at host frame F",
        },
        .{ .long = "button-up", .value = "F:BUTTON", .repeats = true, .help = "release a gamepad button at host frame F" },
        .{
            .long = "stall",
            .value = "F:MS",
            .repeats = true,
            .help = "stop the host for MS milliseconds before host frame F, as a slow\nmachine would",
        },
        .{
            .long = "pcm",
            .value = "FILE",
            .help = "write the audio the game queued (interleaved 16-bit samples) to FILE",
        },
    }),
    .positionals = &.{native.cli.assets},
});

const frame_ns: u64 = std.time.ns_per_s / 60;
const Press = struct {
    frame: u64,
    key: flashbackz.platform.Key,
    mode: enum { tap, down, up, repeat } = .tap,
};
const ButtonPress = struct {
    frame: u64,
    button: flashbackz.platform.ControllerButton,
    down: bool,
};
const Stall = struct { frame: u64, ns: u64 };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    // The arena keeps the arguments for the whole run.
    const arena = init.arena.allocator();
    var diagnostic: clap.Diagnostic = .{};
    const args = Args.parse(arena, try clap.processArguments(arena, init.minimal.args), &diagnostic) catch |err|
        return fail(io, err, diagnostic);
    if (args.help) return help(io);
    const frames = (args.number(u64, "frames", 0, std.math.maxInt(u64), &diagnostic) catch |err|
        return fail(io, err, diagnostic)) orelse 120;
    const options = native.cli.fromArgs(args, &diagnostic) catch |err| return fail(io, err, diagnostic);
    if (options.extract != null) {
        const status = native.cli.extractCommand(gpa, io, "flashbackz-agent", options);
        if (status != 0) std.process.exit(status);
        return;
    }
    if (options.entry == .level_development and options.assets == null) {
        return fail(io, error.MissingArgument, .{ .argument = "ASSET_PATH (--scene with a level needs the disks)" });
    }
    const pcm_path = args.value("pcm");
    var presses: std.ArrayList(Press) = .empty;
    defer presses.deinit(gpa);
    var buttons: std.ArrayList(ButtonPress) = .empty;
    defer buttons.deinit(gpa);
    var stalls: std.ArrayList(Stall) = .empty;
    defer stalls.deinit(gpa);
    // In command-line order: the order of the events at one frame matters.
    for (args.given) |given| {
        const bad: clap.Diagnostic = .{ .argument = Args.flagName(given.option), .value = given.value };
        switch (given.option) {
            Args.index("key"), Args.index("key-down"), Args.index("key-up"), Args.index("key-repeat") => {
                var press = parsePress(given.value) orelse return fail(io, error.InvalidValue, bad);
                press.mode = switch (given.option) {
                    Args.index("key") => .tap,
                    Args.index("key-down") => .down,
                    Args.index("key-up") => .up,
                    else => .repeat,
                };
                try presses.append(gpa, press);
            },
            Args.index("button-down"), Args.index("button-up") => {
                var button = parseButton(given.value) orelse return fail(io, error.InvalidValue, bad);
                button.down = given.option == Args.index("button-down");
                try buttons.append(gpa, button);
            },
            Args.index("stall") => try stalls.append(
                gpa,
                parseStall(given.value) orelse return fail(io, error.InvalidValue, bad),
            ),
            else => {},
        }
    }

    // Real providers when the options name them, else in-memory ones. They outlive the game.
    var providers: native.cli.Providers = .empty;
    defer providers.deinit();
    var memory_assets = flashbackz.memory.MemoryAssetSource.init(gpa);
    defer memory_assets.deinit();
    var memory_storage = flashbackz.memory.MemoryStorage.init(gpa);
    defer memory_storage.deinit();
    var assets: ?flashbackz.platform.AssetSource = memory_assets.assetSource();
    var storage = memory_storage.storage();
    if (options.assets != null or options.saves != null) {
        providers.open(gpa, io, init.environ_map, options) catch |err| {
            var buffer: [256]u8 = undefined;
            var stderr = std.Io.File.stderr().writerStreaming(io, &buffer);
            stderr.interface.writeAll("flashbackz-agent: ") catch {};
            providers.writeFailure(err, &stderr.interface) catch {};
            stderr.interface.flush() catch {};
            std.process.exit(2);
        };
        assets = providers.assetSource() orelse assets;
        storage = providers.storage();
    }

    var backend = agent.AgentBackend.init(gpa, .{});
    defer backend.deinit();
    backend.audio.record = pcm_path != null;
    var game = try flashbackz.Game.initWithEntry(gpa, assets, storage, providers.dataSet(), options.entry);
    defer game.deinit();
    var p = backend.asPlatform();
    var frame: u64 = 0;
    while (frame < frames) : (frame += 1) {
        for (presses.items) |press| if (press.frame == frame) {
            if (press.mode != .up) try backend.inject(.{
                .time_ns = backend.clock_ns,
                .payload = .{ .key_down = .{ .key = press.key, .repeat = press.mode == .repeat } },
            });
            if (press.mode == .tap or press.mode == .up) try backend.inject(.{
                .time_ns = backend.clock_ns,
                .payload = .{ .key_up = .{ .key = press.key } },
            });
        };
        for (buttons.items) |press| if (press.frame == frame) {
            const change: flashbackz.platform.Event.ControllerButtonEvent = .{
                .controller = @fromBackingInt(@intCast(0)),
                .button = press.button,
            };
            try backend.inject(.{
                .time_ns = backend.clock_ns,
                .payload = if (press.down) .{ .controller_button_down = change } else .{ .controller_button_up = change },
            });
        };
        for (stalls.items) |stall| if (stall.frame == frame) backend.advance(stall.ns);
        if (try game.update(&p) == .finished) break;
        backend.advance(frame_ns);
    }

    if (pcm_path) |path| {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        var pcm_buffer: [4096]u8 = undefined;
        var pcm = file.writerStreaming(io, &pcm_buffer);
        for (backend.audio.pcm.items) |sample| try pcm.interface.writeInt(i16, sample, .little);
        try pcm.interface.flush();
    }

    var buf: [512]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &buf);
    try w.interface.print("{{\"updates\":{d},\"frames_presented\":{d},\"events_consumed\":{d},\"saves\":{d},\"loads\":{d},\"state_hash\":\"{x:0>16}\",\"frame_hash\":\"{x:0>16}\"}}\n", .{
        game.update_count, game.frames_presented, game.events_consumed, game.saves_written, game.loads_done, game.stateHash(), game.last_frame_hash,
    });
    if (game.scene == .level) {
        const scene = &game.scene.level;
        const conrad = scene.world.characters[0];
        try w.interface.print(
            "{{\"scene\":\"level\",\"level\":\"{s}\",\"difficulty\":\"{s}\",\"room\":{d},\"x\":{d},\"y\":{d},\"score\":{d},\"catch_up_walks\":{d},\"film\":{},\"sound_fx\":{},\"joystick\":{}}}\n",
            .{
                @tagName(scene.level),
                @tagName(game.difficulty),
                conrad.room,
                conrad.x,
                conrad.y,
                scene.world.score,
                scene.catch_up_walks,
                game.isStoryPlaying(),
                scene.settings.sound_fx,
                scene.settings.joystick,
            },
        );
    } else if (game.scene == .menu) {
        const front = &game.scene.menu;
        try w.interface.print("{{\"scene\":\"menu\",\"stage\":\"{s}\",\"selected\":\"{s}\",\"film_frame\":", .{ @tagName(front.stage), @tagName(front.menu.selected) });
        if (front.player) |player| try w.interface.print("{d}}}\n", .{player.playback.frame}) else try w.interface.print("null}}\n", .{});
    } else {
        try w.interface.print("{{\"scene\":\"{s}\"}}\n", .{@tagName(game.sceneKind())});
    }
    try w.interface.flush();
}

/// `FRAME:NAME`, as `30:f2`.
fn parsePress(text: []const u8) ?Press {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return null;
    const frame = std.fmt.parseInt(u64, text[0..colon], 10) catch return null;
    const key = std.meta.stringToEnum(
        flashbackz.platform.Key,
        text[colon + 1 ..],
    ) orelse return null;
    return .{ .frame = frame, .key = key };
}

/// `FRAME:MS`, as `600:500`.
fn parseStall(text: []const u8) ?Stall {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return null;
    const frame = std.fmt.parseInt(u64, text[0..colon], 10) catch return null;
    const ms = std.fmt.parseInt(u64, text[colon + 1 ..], 10) catch return null;
    return .{ .frame = frame, .ns = ms * std.time.ns_per_ms };
}

/// `FRAME:BUTTON`, as `30:dpad_left`.
fn parseButton(text: []const u8) ?ButtonPress {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return null;
    const frame = std.fmt.parseInt(u64, text[0..colon], 10) catch return null;
    const button = std.meta.stringToEnum(
        flashbackz.platform.ControllerButton,
        text[colon + 1 ..],
    ) orelse return null;
    return .{ .frame = frame, .button = button, .down = true };
}

fn fail(io: std.Io, err: clap.Error, diagnostic: clap.Diagnostic) !void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    try Args.writeError(&w.interface, err, diagnostic);
    try w.interface.flush();
    std.process.exit(2);
}

fn help(io: std.Io) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &buf);
    try Args.writeHelp(&w.interface);
    try w.interface.flush();
}
