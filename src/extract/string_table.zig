//! A level's labels file (offset-indexed strings) read for the extractor: each label an owned
//! byte string.
const std = @import("std");

pub fn copy(allocator: std.mem.Allocator, file: []const u8, index: u16) ![]u8 {
    if (file.len < 2) return error.InvalidStringDirectory;
    const end = std.mem.readInt(u16, file[0..2], .little);
    if (end < 2 or end % 2 != 0 or end > file.len) return error.InvalidStringDirectory;
    if (index >= end / 2) return error.MissingString;
    const offset = std.mem.readInt(u16, file[@as(usize, index) * 2 ..][0..2], .little);
    if (offset < end or offset >= file.len) return error.InvalidStringOffset;
    const length = std.mem.indexOfScalar(u8, file[offset..], 0) orelse return error.UnterminatedString;
    if (length > 256) return error.StringTooLong;
    return allocator.dupe(u8, file[offset..][0..length]);
}

test "labels support aliases and empty text while rejecting missing terminators" {
    const allocator = std.testing.allocator;
    const file = [_]u8{ 6, 0, 7, 0, 7, 0, 0, 'A', 'B', 0 };
    const a = try copy(allocator, &file, 1);
    defer allocator.free(a);
    try std.testing.expectEqualStrings("AB", a);
    // Entry 2 points at entry 1's text.
    const alias = try copy(allocator, &file, 2);
    defer allocator.free(alias);
    try std.testing.expectEqualStrings("AB", alias);
    const empty = try copy(allocator, &file, 0);
    defer allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.expectError(error.MissingString, copy(allocator, &file, 3));
    try std.testing.expectError(error.UnterminatedString, copy(allocator, file[0..9], 1));
}
