//! The agent platform: a backend with scripted devices, a controlled clock and captured output. A
//! port drives its game through it to test and to debug without a window: the same input gives the
//! same frames on every machine. A port grows a driver on top of it for its tests (DESIGN.md).
pub const AgentBackend = backend.AgentBackend;
const backend = @import("backend.zig");
const startup_test = @import("startup_test.zig");
const audio_test = @import("audio_test.zig");
const std = @import("std");

test {
    _ = startup_test;
    _ = audio_test;
    std.testing.refAllDecls(@This());
}
