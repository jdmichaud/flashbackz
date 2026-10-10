//! The standalone build's check of the user's files (DESIGN.md 3), run by build.zig before it
//! builds them into flashbackz-sdl: each disk must be a floppy image the game reads, the cartridge
//! the accepted Mega Drive cartridge. Usage: bundle_check (disk PATH | megadrive PATH)...
const std = @import("std");
const flashbackz = @import("flashbackz");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var buffer: [512]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &buffer);
    const out = &stderr.interface;
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 2) {
        const kind = args[i];
        const path = args[i + 1];
        const what = if (std.mem.eql(u8, kind, "megadrive")) "Mega Drive cartridge" else "disk";
        const limit: std.Io.Limit = .limited(4 * 1024 * 1024);
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, limit) catch |err| {
            const name = switch (err) {
                error.FileNotFound => "not found",
                error.AccessDenied => "permission denied",
                error.IsDir => "a directory",
                else => @errorName(err),
            };
            try out.print("standalone build: cannot read the {s} {s}: {s}\n", .{
                what,
                path,
                name,
            });
            try out.flush();
            return 1;
        };
        defer gpa.free(bytes);
        const why: ?[]const u8 = if (std.mem.eql(u8, kind, "megadrive"))
            if (flashbackz.content.megadrive.isCartridge(bytes))
                null
            else
                "not the cartridge Flashback (Europe) (En,Fr)"
        else if (flashbackz.floppy.load(gpa, bytes)) |loaded| ok: {
            var imported = loaded;
            imported.deinit();
            break :ok null;
        } else |_| "not a floppy image of the game";
        if (why) |reason| {
            try out.print("standalone build: the {s} {s} is {s}\n", .{ what, path, reason });
            try out.flush();
            return 1;
        }
    }
    return 0;
}
