//! A level's collision file (`.CT`), decoded: four 64-entry tables of each room's neighbor (up,
//! down, right, left; 0xff for none), then 64 rooms of 7 rows by 16 columns, each byte a cell's
//! material (0 for none). The engine's grid (`behavior/grid.zig`) probes these bytes as the
//! original lays them out.
const std = @import("std");
const backward_stream = @import("backward_stream.zig");

pub const rooms = 64;
pub const rows = 7;
pub const columns = 16;
pub const size = 4 * rooms + rooms * rows * columns;
pub const Bytes = [size]u8;

/// Decodes the packed collision file.
pub fn decode(allocator: std.mem.Allocator, packed_file: []const u8) !Bytes {
    const decoded = try backward_stream.decode(allocator, packed_file, size);
    defer allocator.free(decoded);
    if (decoded.len != size) return error.InvalidCollisionLayout;
    return decoded[0..size].*;
}
