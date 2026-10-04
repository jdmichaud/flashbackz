//! Host memory availability is presentation metadata, never simulation state.
const std = @import("std");
const builtin = @import("builtin");
const File = opaque {};
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*File;
extern "c" fn fgets(buffer: [*]u8, size: c_int, file: *File) ?[*]u8;
extern "c" fn fclose(file: *File) c_int;

pub fn availableBytes() ?u64 {
    if (builtin.os.tag != .linux) return null;
    const file = fopen("/proc/meminfo", "r") orelse return null;
    defer _ = fclose(file);
    var buffer: [256]u8 = undefined;
    for (0..128) |_| {
        if (fgets(&buffer, buffer.len, file) == null) return null;
        const line = std.mem.sliceTo(&buffer, 0);
        if (parseAvailable(line)) |value| return value;
    }
    return null;
}
fn parseAvailable(line: []const u8) ?u64 {
    const prefix = "MemAvailable:";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    var words = std.mem.tokenizeAny(u8, line[prefix.len..], " \t\r\n");
    const amount = std.fmt.parseInt(u64, words.next() orelse return null, 10) catch return null;
    if (!std.mem.eql(u8, words.next() orelse return null, "kB")) return null;
    return std.math.mul(u64, amount, 1024) catch null;
}
test "available memory uses reclaimable availability and validates the unit" {
    try std.testing.expectEqual(@as(?u64, 42 * 1024), parseAvailable("MemAvailable: 42 kB\n"));
    try std.testing.expect(parseAvailable("MemTotal: 42 kB") == null);
    try std.testing.expect(parseAvailable("MemAvailable: 42 MB") == null);
}
