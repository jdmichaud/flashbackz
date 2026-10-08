//! Persist the user's master gain through the host's atomic storage interface.
const std = @import("std");
const platform = @import("platform.zig");
pub const key = "VOLUME";
pub const default: u8 = 100;

pub fn load(storage: ?platform.Storage) u8 {
    const source = storage orelse return default;
    var record = source.load(key) catch return default;
    defer record.deinit();
    const value = std.fmt.parseInt(
        u8,
        std.mem.trim(u8, record.bytes, " \t\r\n"),
        10,
    ) catch return default;
    return if (value <= 100) value else default;
}

pub fn save(storage: ?platform.Storage, value: u8) platform.StorageError!void {
    const destination = storage orelse return;
    std.debug.assert(value <= 100);
    var buffer: [4]u8 = undefined;
    const record = std.fmt.bufPrint(&buffer, "{d}\n", .{value}) catch unreachable;
    try destination.save(key, record);
}
