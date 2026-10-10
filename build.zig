//! flashbackz build graph.
//!
//! Targets:
//!   flashbackz-agent      headless debugging host (shared game + AgentBackend), never links SDL
//!   flashbackz            the game: the SDL interactive host (Linux, Windows)
//!   flashbackz-standalone the game with the user's files built in, only with -Ddisk1, -Ddisk2
//!                         and -Dmegadrive (DESIGN.md 3)
//!   flashbackz-atlas      a PNG poster of every level's rooms, from the user's disks
//! The hosts write the readable data set with `--extract DIR`.
//! Steps: `zig build` installs both native hosts. `test` runs standalone unit tests;
//! `smoke` exercises the headless host; `verify` checks that it has no SDL dependency.
//! `all` installs both native hosts and the atlas for the selected target; `atlas` only the
//! atlas.
const std = @import("std");

/// The compiler release used by this project's builds and checks.
pub const pinned_zig_version = "0.17.0";

/// The SDL2 release that the Linux host is built and tested against.
pub const pinned_sdl_version = "2.32.4";

/// The SDL2 release that a Windows build links: the `sdl2` package of build.zig.zon,
/// allyourcodebase's SDL2 built from source by Zig. Keep it with the package's version.
pub const package_sdl_version = "2.32.10";

const SdlLinkage = enum { static, dynamic };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sdl_linkage = b.option(
        SdlLinkage,
        "sdl-linkage",
        "Link the system SDL2 as a static archive or as a shared library (default: static). A Windows build always links its SDL2 statically",
    ) orelse .static;

    const versions = b.addOptions();

    // Shared code: the platform contract, in-memory providers, the game. No host library, no libc.
    const shared = b.addModule("flashbackz", .{
        .root_source_file = b.path("src/shared/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    shared.addOptions("build_versions", versions);

    // Agent platform: injected events, controlled time, captured output.
    const agent = b.addModule("agent", .{
        .root_source_file = b.path("src/agent/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "flashbackz", .module = shared }},
    });

    // The extractor's core: the user's game files to the readable data set, in memory.
    const extract_library = b.addModule("extract", .{
        .root_source_file = b.path("src/extract/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "flashbackz", .module = shared }},
    });

    // Native I/O: the directory asset source, the directory storage and the data set over
    // std.Io. The executables import it; `flashbackz` never does.
    const native = b.addModule("native", .{
        .root_source_file = b.path("src/native/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "flashbackz", .module = shared },
            .{ .name = "extract", .module = extract_library },
        },
    });

    // SDL platform: the only module that links SDL2, and thus libc. It imports `native` for the
    // asset and save providers of the host, which link nothing, and `c`, SDL2's API translated
    // from the headers of the SDL2 it links.
    const sdl_api = b.addTranslateC(.{
        .root_source_file = b.path("src/sdl/c.h"),
        .target = target,
        .optimize = optimize,
    });
    // The standalone build's files (DESIGN.md 3), built into flashbackz-standalone only.
    const disks = [2]?[]const u8{
        b.option([]const u8, "disk1", "Standalone build: the first floppy image, built in"),
        b.option([]const u8, "disk2", "Standalone build: the second floppy image, built in"),
    };
    const cartridge = b.option(
        []const u8,
        "megadrive",
        "Standalone build: the Mega Drive cartridge Flashback (Europe) (En,Fr), built in",
    );
    const sdl = b.addModule("sdl", .{
        .root_source_file = b.path("src/sdl/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "flashbackz", .module = shared },
            .{ .name = "native", .module = native },
            .{ .name = "c", .module = sdl_api.createModule() },
        },
    });
    if (target.result.os.tag == .windows)
        linkPackagedSdl(b, sdl, sdl_api, target, versions)
    else
        linkSdl(b, sdl, sdl_api, sdl_linkage, versions);

    const agent_exe = b.addExecutable(.{
        .name = "flashbackz-agent",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/agent/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "flashbackz", .module = shared },
                .{ .name = "agent", .module = agent },
                .{ .name = "native", .module = native },
            },
        }),
    });

    const atlas = b.createModule(.{
        .root_source_file = b.path("src/atlas/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "flashbackz", .module = shared },
            .{ .name = "native", .module = native },
        },
    });
    const atlas_exe = b.addExecutable(.{ .name = "flashbackz-atlas", .root_module = atlas });
    const install_atlas = b.addInstallArtifact(atlas_exe, .{});

    // The game, and the standalone build when its files are given.
    const game: Game = .{
        .target = target,
        .optimize = optimize,
        .shared = shared,
        .sdl = sdl,
        .native = native,
    };
    const no_files = builtInFiles(b, versions, "flashbackz", .{ null, null }, null);
    const sdl_exe = game.executable(b, "flashbackz", no_files);
    const any_file = disks[0] != null or disks[1] != null or cartridge != null;
    const standalone_exe = if (any_file) standalone: {
        const files = builtInFiles(b, versions, "flashbackz-standalone", disks, cartridge);
        break :standalone game.executable(b, "flashbackz-standalone", files);
    } else null;

    b.installArtifact(agent_exe);
    b.installArtifact(sdl_exe);
    if (standalone_exe) |exe| b.installArtifact(exe);

    b.step(
        "agent",
        "Build and install only the headless agent host",
    ).dependOn(&b.addInstallArtifact(agent_exe, .{}).step);
    b.step(
        "atlas",
        "Build and install only the level atlas, flashbackz-atlas",
    ).dependOn(&install_atlas.step);
    const sdl_step = b.step(
        "sdl",
        "Build and install only the SDL game (and its standalone build with the -D options)",
    );
    sdl_step.dependOn(&b.addInstallArtifact(sdl_exe, .{}).step);
    if (standalone_exe) |exe| sdl_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    // Unit tests of every module. The tests of the SDL module link SDL2 as the host does.
    const test_step = b.step("test", "Run the unit tests of every module");
    const unit_modules = [_]*std.Build.Module{
        shared,
        agent,
        native,
        sdl,
        extract_library,
        atlas,
    };
    for (unit_modules) |m| {
        const t = b.addTest(.{ .root_module = m });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // The agent host for a few frames, with a save and a load. It needs no game files and no
    // display.
    const smoke = b.addRunArtifact(agent_exe);
    smoke.addArgs(&.{ "--frames", "60", "--key", "10:f2", "--key", "20:f3" });
    smoke.expectExitCode(0);
    b.step("smoke", "Run the agent host for a few frames").dependOn(&smoke.step);

    // The agent binary must have no SDL dependency.
    const no_sdl = b.addSystemCommand(&.{ "sh", "tools/check_no_sdl.sh" });
    no_sdl.addArtifactArg(agent_exe);
    no_sdl.expectExitCode(0);
    b.step("verify", "Check the agent host binary links no SDL library").dependOn(&no_sdl.step);

    const all_step = b.step(
        "all",
        "Build and install both native hosts and the atlas for the selected target",
    );
    all_step.dependOn(b.getInstallStep());
    all_step.dependOn(&install_atlas.step);
}

/// The SDL game's modules, from which `flashbackz` and `flashbackz-standalone` are built.
const Game = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    shared: *std.Build.Module,
    sdl: *std.Build.Module,
    native: *std.Build.Module,

    fn executable(
        game: Game,
        b: *std.Build,
        name: []const u8,
        built_in: *std.Build.Module,
    ) *std.Build.Step.Compile {
        return b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/sdl/main.zig"),
                .target = game.target,
                .optimize = game.optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "flashbackz", .module = game.shared },
                    .{ .name = "sdl", .module = game.sdl },
                    .{ .name = "native", .module = game.native },
                    .{ .name = "built_in", .module = built_in },
                },
            }),
        });
    }
};

/// An executable's name and built-in files (DESIGN.md 3): the user's disks and cartridge
/// embedded, once `bundle_check` has accepted them; none without them. The module is generated in
/// the cache and holds original files: it never enters the repository.
fn builtInFiles(
    b: *std.Build,
    versions: *std.Build.Step.Options,
    program: []const u8,
    disks: [2]?[]const u8,
    cartridge: ?[]const u8,
) *std.Build.Module {
    const files = b.addWriteFiles();
    var embeds: []const u8 = "";
    if (disks[0] != null or disks[1] != null or cartridge != null) {
        const host_shared = b.createModule(.{
            .root_source_file = b.path("src/shared/root.zig"),
            .target = b.graph.host,
        });
        host_shared.addOptions("build_versions", versions);
        const checker = b.addExecutable(.{
            .name = "bundle_check",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/native/bundle_check.zig"),
                .target = b.graph.host,
                .imports = &.{.{ .name = "flashbackz", .module = host_shared }},
            }),
        });
        const check = b.addRunArtifact(checker);
        for (disks, 1..) |disk, number| if (disk) |path| {
            check.addArg("disk");
            check.addFileArg(.{ .cwd_relative = path });
            const name = b.fmt("disk{d}.img", .{number});
            _ = files.addCopyFile(.{ .cwd_relative = path }, name);
            embeds = b.fmt("{s}@embedFile(\"{s}\"), ", .{ embeds, name });
        };
        if (cartridge) |path| {
            check.addArg("megadrive");
            check.addFileArg(.{ .cwd_relative = path });
            _ = files.addCopyFile(.{ .cwd_relative = path }, "megadrive.md");
        }
        files.step.dependOn(&check.step);
    }
    const source = files.add("built_in.zig", b.fmt(
        \\//! Generated by build.zig: the executable's name, and the user's files it holds (the
        \\//! standalone build). Never commit.
        \\pub const program = "{s}";
        \\pub const disks: []const []const u8 = &.{{ {s}}};
        \\pub const megadrive: ?[]const u8 = {s};
        \\
    , .{ program, embeds, if (cartridge != null) "@embedFile(\"megadrive.md\")" else "null" }));
    return b.createModule(.{ .root_source_file = source });
}

/// Links SDL2 into `m`, translates the headers that pkg-config names for `api`, and records the
/// SDL2 version that pkg-config reports as the `sdl` build option. Static linkage uses the archive
/// that pkg-config names and the system libraries of its static link line. Those libraries stay
/// dynamic, because static builds of X11, Wayland or PulseAudio are not practical. Dynamic linkage
/// uses the shared library.
fn linkSdl(
    b: *std.Build,
    m: *std.Build.Module,
    api: *std.Build.Step.TranslateC,
    linkage: SdlLinkage,
    versions: *std.Build.Step.Options,
) void {
    var code: u8 = 0;
    const include_out = b.runAllowFail(
        &.{ "pkg-config", "--cflags-only-I", "sdl2" },
        &code,
        .ignore,
    ) catch {
        std.log.err("the SDL host needs pkg-config to locate SDL2's headers", .{});
        std.process.exit(1);
    };
    var include_flags = std.mem.tokenizeAny(u8, include_out, " \t\r\n");
    while (include_flags.next()) |flag| {
        if (std.mem.startsWith(u8, flag, "-I"))
            api.addSystemIncludePath(.{ .cwd_relative = b.dupe(flag[2..]) });
    }

    if (b.runAllowFail(&.{ "pkg-config", "--modversion", "sdl2" }, &code, .ignore)) |out| {
        const found = std.mem.trim(u8, out, " \t\r\n");
        versions.addOption([]const u8, "sdl", found);
    } else |_| {
        std.log.warn(
            "pkg-config could not report the SDL2 version; the pin ({s}) is checked at run time only",
            .{pinned_sdl_version},
        );
        versions.addOption([]const u8, "sdl", "unknown");
    }

    switch (linkage) {
        .dynamic => m.linkSystemLibrary("SDL2", .{}),
        .static => {
            const libdir_out = b.runAllowFail(
                &.{ "pkg-config", "--variable=libdir", "sdl2" },
                &code,
                .ignore,
            ) catch {
                std.log.err(
                    "static SDL2 linkage needs pkg-config to locate libSDL2.a; use -Dsdl-linkage=dynamic",
                    .{},
                );
                std.process.exit(1);
            };
            const libdir = std.mem.trim(u8, libdir_out, " \t\r\n");
            m.addObjectFile(.{ .cwd_relative = b.fmt("{s}/libSDL2.a", .{libdir}) });
            const libs_out = b.runAllowFail(
                &.{ "pkg-config", "--static", "--libs", "sdl2" },
                &code,
                .ignore,
            ) catch {
                std.log.err(
                    "pkg-config --static --libs sdl2 failed; use -Dsdl-linkage=dynamic",
                    .{},
                );
                std.process.exit(1);
            };
            var it = std.mem.tokenizeAny(u8, libs_out, " \t\r\n");
            while (it.next()) |flag| {
                if (std.mem.eql(u8, flag, "-lSDL2")) continue;
                if (std.mem.eql(u8, flag, "-pthread")) continue;
                if (std.mem.startsWith(u8, flag, "-l")) {
                    m.linkSystemLibrary(flag[2..], .{ .use_pkg_config = .no });
                } else if (std.mem.startsWith(u8, flag, "-L")) {
                    m.addLibraryPath(.{ .cwd_relative = b.dupe(flag[2..]) });
                }
            }
        },
    }
}

/// A Windows build: SDL2 compiled from source by Zig for the target (the `sdl2` package), linked
/// statically with the Windows libraries that it needs, and `api` translated from the package's
/// headers. The package is fetched on the first Windows build; Linux builds never fetch it. SDL
/// is optimised whatever the game's mode, as the system library of a Linux build is.
fn linkPackagedSdl(
    b: *std.Build,
    m: *std.Build.Module,
    api: *std.Build.Step.TranslateC,
    target: std.Build.ResolvedTarget,
    versions: *std.Build.Step.Options,
) void {
    versions.addOption([]const u8, "sdl", package_sdl_version);
    const dep = b.lazyDependency(
        "sdl2",
        .{ .target = target, .optimize = .ReleaseFast },
    ) orelse return;
    m.linkLibrary(dep.artifact("SDL2"));
    // The package's own header directories. The library's emitted include tree comes out empty
    // on an sshfs checkout: Zig 0.17.0's directory walk reports each entry's kind as unknown
    // there, and the copy into the tree skips it (flashback-re docs/tool-defects.md, 2026-10-09).
    api.addIncludePath(dep.path("include-pregen"));
    api.addIncludePath(dep.path("include"));
}
