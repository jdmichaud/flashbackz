//! flashbackz-agent: the headless host. It runs the game on the agent backend for a number of frames,
//! at a fixed 60 Hz clock, presses keys at the frames it is told, and prints one JSON line with the
//! counts and the hashes of the state and of the last frame. Two runs with the same arguments print
//! the same line on every machine; a port builds its scripted tests and its debugging on this.
//!
//! The game reads its files from the asset paths (both floppy images, or a directory extracted from
//! them); without them it stops with a message. With `--saves` it saves there; without it, in
//! memory: a run touches no file it is not given.
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
            .long = "axis",
            .value = "F:AXIS:VALUE",
            .repeats = true,
            .help = "move a gamepad axis (a platform.ControllerAxis, as left_x) to VALUE\n" ++
                "(-32768 to 32767) at host frame F",
        },
        .{
            .long = "save",
            .value = "F:SLOT",
            .repeats = true,
            .help = "save the level in play into SLOT (QUICK, SAVE1 to SAVE8) at the end of host\n" ++
                "frame F",
        },
        .{ .long = "load", .value = "F:SLOT", .repeats = true, .help = "load SLOT at the end of host frame F" },
        .{ .long = "trace", .help = "print the level's state hash after each of its walks" },
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
const AxisMove = struct {
    frame: u64,
    axis: flashbackz.platform.ControllerAxis,
    value: i16,
};
const Stall = struct { frame: u64, ns: u64 };
const SaveAction = struct { frame: u64, slot: []const u8, load: bool };

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
    var options = native.cli.fromArgs(args, &diagnostic) catch |err| return fail(io, err, diagnostic);
    options.default_saves = .memory;
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
    var axes: std.ArrayList(AxisMove) = .empty;
    defer axes.deinit(gpa);
    var stalls: std.ArrayList(Stall) = .empty;
    defer stalls.deinit(gpa);
    var saves: std.ArrayList(SaveAction) = .empty;
    defer saves.deinit(gpa);
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
            Args.index("axis") => try axes.append(
                gpa,
                parseAxis(given.value) orelse return fail(io, error.InvalidValue, bad),
            ),
            Args.index("save"), Args.index("load") => {
                const colon = std.mem.indexOfScalar(u8, given.value, ':') orelse return fail(io, error.InvalidValue, bad);
                const frame = std.fmt.parseInt(u64, given.value[0..colon], 10) catch return fail(io, error.InvalidValue, bad);
                try saves.append(gpa, .{
                    .frame = frame,
                    .slot = given.value[colon + 1 ..],
                    .load = given.option == Args.index("load"),
                });
            },
            Args.index("stall") => try stalls.append(
                gpa,
                parseStall(given.value) orelse return fail(io, error.InvalidValue, bad),
            ),
            else => {},
        }
    }

    // The files the options name, and saves in memory unless they name a directory. The providers
    // outlive the game.
    var providers: native.cli.Providers = .empty;
    defer providers.deinit();
    var memory_storage = flashbackz.memory.MemoryStorage.init(gpa);
    defer memory_storage.deinit();
    var assets: ?flashbackz.platform.AssetSource = null;
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
        assets = providers.assetSource();
        if (providers.storage()) |directory| storage = directory;
    }
    if (assets == null) {
        var buffer: [256]u8 = undefined;
        var stderr = std.Io.File.stderr().writerStreaming(io, &buffer);
        stderr.interface.writeAll("flashbackz-agent: the game's files are missing: give both floppy images " ++
            "(disk1.img disk2.img) or a directory extracted from them\n") catch {};
        stderr.interface.flush() catch {};
        std.process.exit(2);
    }

    var backend = agent.AgentBackend.init(gpa, .{});
    defer backend.deinit();
    backend.audio.record = pcm_path != null;
    var game = try flashbackz.Game.initWithEntry(gpa, assets, storage, providers.dataSet(), options.entry);
    defer game.deinit();
    var p = backend.asPlatform();
    // A session with a pad has it connected from the start, as SDL reports one.
    if (buttons.items.len != 0 or axes.items.len != 0) try backend.inject(.{
        .time_ns = backend.clock_ns,
        .payload = .{ .controller_added = @fromBackingInt(@intCast(0)) },
    });
    const trace = args.flag("trace");
    var traced_walks: u64 = 0;
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
        for (axes.items) |move| if (move.frame == frame) try backend.inject(.{
            .time_ns = backend.clock_ns,
            .payload = .{ .controller_axis = .{
                .controller = @fromBackingInt(@intCast(0)),
                .axis = move.axis,
                .value = move.value,
            } },
        });
        for (stalls.items) |stall| if (stall.frame == frame) backend.advance(stall.ns);
        if (try game.update(&p) == .finished) break;
        if (trace and game.scene == .level and game.scene.level.walk_count != traced_walks) {
            traced_walks = game.scene.level.walk_count;
            std.debug.print("{{\"frame\":{d},\"walks\":{d},\"state_hash\":\"{x:0>16}\"}}\n", .{ frame, traced_walks, game.scene.level.stateHash() });
        }
        for (saves.items) |action| if (action.frame == frame) {
            const result = if (action.load) game.loadGame(action.slot) else game.saveGame(&p, action.slot);
            result catch |err| std.debug.print("flashbackz-agent: {s} {s}: {s}\n", .{
                if (action.load) "load" else "save",
                action.slot,
                @errorName(err),
            });
            if (trace) std.debug.print("{{\"frame\":{d},\"{s}\":\"{s}\"}}\n", .{ frame, if (action.load) "load" else "save", action.slot });
            // A loaded level counts its walks from none.
            if (action.load) traced_walks = 0;
        };
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
    try w.interface.print("{{\"updates\":{d},\"frames_presented\":{d},\"events_consumed\":{d},\"state_hash\":\"{x:0>16}\",\"frame_hash\":\"{x:0>16}\"}}\n", .{
        game.update_count, game.frames_presented, game.events_consumed, game.stateHash(), game.last_frame_hash,
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
                game.settings.sound_fx,
                game.settings.joystick,
            },
        );
    } else if (game.scene == .menu) {
        const front = &game.scene.menu;
        try w.interface.print("{{\"scene\":\"menu\",\"stage\":\"{s}\",\"page\":\"{s}\",\"selected\":\"{s}\",\"film_frame\":", .{
            @tagName(front.stage),
            @tagName(front.view),
            @tagName(front.menu.selected),
        });
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

/// `FRAME:AXIS:VALUE`, as `30:left_x:-32768`.
fn parseAxis(text: []const u8) ?AxisMove {
    var parts = std.mem.splitScalar(u8, text, ':');
    const frame = std.fmt.parseInt(u64, parts.next() orelse return null, 10) catch return null;
    const axis = std.meta.stringToEnum(flashbackz.platform.ControllerAxis, parts.next() orelse return null) orelse return null;
    const value = std.fmt.parseInt(i16, parts.next() orelse return null, 10) catch return null;
    if (parts.next() != null) return null;
    return .{ .frame = frame, .axis = axis, .value = value };
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
