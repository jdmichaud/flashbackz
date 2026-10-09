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

const usage =
    \\usage: flashbackz-agent [--frames N] [--key FRAME:NAME]... [ASSET_PATH...] [--saves DIR]
    \\  --frames N       run N frames (default 120)
    \\  --key FRAME:NAME press and release the key NAME (a platform.Key, as `f2` or `left`) at
    \\                   frame FRAME; the option repeats
    \\  --key-down F:KEY hold KEY from host frame F
    \\  --key-up F:KEY   release KEY at host frame F
    \\  --scene menu     open the title preview while floppy startup is being recovered
    \\  ASSET_PATH       FAT12 images or extracted directories; repeat for all disks
    \\  --saves DIR      where saves are kept
    \\  --pcm FILE       write the audio the game queued (interleaved 16-bit samples) to FILE
    \\  --button-down F:BUTTON, --button-up F:BUTTON
    \\                   press or release a gamepad button (a platform.ControllerButton, as `a`
    \\                   or `dpad_left`) at host frame F
    \\
;

const frame_ns: u64 = std.time.ns_per_s / 60;
const Press = struct {
    frame: u64,
    key: flashbackz.platform.Key,
    mode: enum { tap, down, up } = .tap,
};
const ButtonPress = struct {
    frame: u64,
    button: flashbackz.platform.ControllerButton,
    down: bool,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var frames: u64 = 120;
    var pcm_path: ?[]const u8 = null;
    var presses: std.ArrayList(Press) = .empty;
    defer presses.deinit(gpa);
    var buttons: std.ArrayList(ButtonPress) = .empty;
    defer buttons.deinit(gpa);
    var options: native.cli.Options = .{};
    // `iterateAllocator` is the form that Windows needs; the arena keeps the arguments for the
    // whole run.
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.skip();
    while (args.next()) |arg| {
        if (options.take(arg, &args) catch return fail(io)) continue;
        if (std.mem.eql(u8, arg, "--frames")) {
            frames = std.fmt.parseInt(
                u64,
                args.next() orelse return fail(io),
                10,
            ) catch return fail(io);
        } else if (std.mem.eql(u8, arg, "--pcm")) {
            pcm_path = args.next() orelse return fail(io);
        } else if (std.mem.eql(u8, arg, "--key")) {
            try presses.append(
                gpa,
                parsePress(args.next() orelse return fail(io)) orelse return fail(io),
            );
        } else if (std.mem.eql(u8, arg, "--button-down") or std.mem.eql(u8, arg, "--button-up")) {
            var button = parseButton(args.next() orelse return fail(io)) orelse return fail(io);
            button.down = std.mem.eql(u8, arg, "--button-down");
            try buttons.append(gpa, button);
        } else if (std.mem.eql(u8, arg, "--key-down") or std.mem.eql(u8, arg, "--key-up")) {
            var press = parsePress(args.next() orelse return fail(io)) orelse return fail(io);
            press.mode = if (std.mem.eql(u8, arg, "--key-down")) .down else .up;
            try presses.append(gpa, press);
        } else {
            return fail(io);
        }
    }
    if (options.entry == .level_development and options.assets == null) return fail(io);

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
            std.log.err("cannot open the providers: {s}", .{@errorName(err)});
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
                .payload = .{ .key_down = .{ .key = press.key } },
            });
            if (press.mode != .down) try backend.inject(.{
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
            "{{\"scene\":\"level\",\"level\":\"{s}\",\"difficulty\":\"{s}\",\"room\":{d},\"x\":{d},\"y\":{d},\"score\":{d}}}\n",
            .{
                @tagName(scene.level),
                @tagName(game.difficulty),
                conrad.room,
                conrad.x,
                conrad.y,
                scene.world.score,
            },
        );
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

fn fail(io: std.Io) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    try w.interface.writeAll(usage);
    try w.interface.flush();
    std.process.exit(2);
}
