//! flashback, and flashback-standalone with the user's files built in (DESIGN.md 3): the
//! interactive SDL host. The entry point only creates the process resources and
//! gives them to `sdl.host.run`. That function owns the backend, the providers, the game and the
//! outer loop.
const std = @import("std");
const sdl = @import("sdl");
const native = @import("native");
const built_in = @import("built_in");
const clap = native.clap;

const program = built_in.program;
const Args = sdl.host.Args(program);

pub fn main(init: std.process.Init) !void {
    // The arena keeps the arguments for the whole run.
    const arena = init.arena.allocator();
    const args = try clap.processArguments(arena, init.minimal.args);
    var diagnostic: clap.Diagnostic = .{};
    const files: native.cli.BuiltIn = .{ .disks = built_in.disks, .megadrive = built_in.megadrive };
    const options = sdl.host.parseArgs(program, arena, args, &diagnostic, files) catch |err| {
        var buf: [1024]u8 = undefined;
        var w = std.Io.File.stderr().writerStreaming(init.io, &buf);
        if (err == error.MissingAssets) {
            const needs = "--scene with a level needs the disks (ASSET_PATH)";
            try w.interface.print("{s}: {s}\n", .{ program, needs });
            try Args.writeUsage(&w.interface);
        } else try Args.writeError(&w.interface, @errorCast(err), diagnostic);
        try w.interface.flush();
        std.process.exit(2);
    };
    // Extracting writes the data set without opening a window.
    if (options.providers.extract != null) {
        const status = native.cli.extractCommand(init.gpa, init.io, program, options.providers);
        if (status != 0) std.process.exit(status);
        return;
    }
    if (options.help) {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stdout().writerStreaming(init.io, &buf);
        try Args.writeHelp(&w.interface);
        return w.interface.flush();
    }
    const status = try sdl.host.run(init.gpa, init.io, init.environ_map, options);
    if (status != 0) std.process.exit(status);
}
