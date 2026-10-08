//! flashbackz build graph.
//!
//! Targets:
//!   flashbackz-agent  headless debugging host (shared game + AgentBackend), never links SDL
//!   flashbackz-sdl    SDL interactive host (Linux, Windows)
//! Steps: `zig build` installs both native hosts. `test` runs standalone unit tests;
//! `smoke` exercises the headless host; `verify` checks that it has no SDL dependency.
//! `all` installs both native hosts for the selected target.
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

    // Native I/O: the directory asset source and the directory storage over std.Io. The executables import it; `flashbackz` never does.
    const native = b.addModule("native", .{
        .root_source_file = b.path("src/native/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "flashbackz", .module = shared }},
    });

    // SDL platform: the only module that links SDL2, and thus libc. It imports `native` for the
    // asset and save providers of the host, which link nothing.
    const sdl = b.addModule("sdl", .{
        .root_source_file = b.path("src/sdl/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "flashbackz", .module = shared },
            .{ .name = "native", .module = native },
        },
    });
    if (target.result.os.tag == .windows)
        linkPackagedSdl(b, sdl, target, versions)
    else
        linkSdl(b, sdl, sdl_linkage, versions);

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

    const sdl_exe = b.addExecutable(.{
        .name = "flashbackz-sdl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sdl/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "flashbackz", .module = shared },
                .{ .name = "sdl", .module = sdl },
                .{ .name = "native", .module = native },
            },
        }),
    });

    b.installArtifact(agent_exe);
    b.installArtifact(sdl_exe);

    b.step(
        "agent",
        "Build and install only the headless agent host",
    ).dependOn(&b.addInstallArtifact(agent_exe, .{}).step);
    b.step(
        "sdl",
        "Build and install only the SDL host",
    ).dependOn(&b.addInstallArtifact(sdl_exe, .{}).step);
    // Unit tests of every module. The tests of the SDL module link SDL2 as the host does.
    const test_step = b.step("test", "Run the unit tests of every module");
    const unit_modules = [_]*std.Build.Module{ shared, agent, native, sdl };
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

    b.step(
        "all",
        "Build and install both native hosts for the selected target",
    ).dependOn(b.getInstallStep());
}

/// Links SDL2 into `m`, and records the SDL2 version that pkg-config reports as the `sdl` build
/// option. Static linkage uses the archive that pkg-config names and the system libraries of its
/// static link line. Those libraries stay dynamic, because static builds of X11, Wayland or
/// PulseAudio are not practical. Dynamic linkage uses the shared library.
fn linkSdl(
    b: *std.Build,
    m: *std.Build.Module,
    linkage: SdlLinkage,
    versions: *std.Build.Step.Options,
) void {
    var code: u8 = 0;
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
/// statically with the Windows libraries that it needs. The package is fetched on the first Windows
/// build; Linux builds never fetch it. SDL is optimised whatever the game's mode, as the system
/// library of a Linux build is.
fn linkPackagedSdl(
    b: *std.Build,
    m: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    versions: *std.Build.Step.Options,
) void {
    versions.addOption([]const u8, "sdl", package_sdl_version);
    const dep = b.lazyDependency(
        "sdl2",
        .{ .target = target, .optimize = .ReleaseFast },
    ) orelse return;
    m.linkLibrary(dep.artifact("SDL2"));
}
