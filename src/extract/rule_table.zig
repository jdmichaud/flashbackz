//! Bounded legacy rule records for semantic content import, never runtime dispatch.
const std = @import("std");
pub const Operation = struct {
    code: u8,
    argument: i16,
};
pub const Rule = struct {
    source: u16,
    target: u16,
    dx: i8,
    dy: i8,
    flags: u8,
    next: u16,
    conditions: [2]Operation,
    effect: Operation,
};
pub const Group = struct {
    records: []const u8,
    pub fn count(self: Group) usize {
        return self.records.len / 18;
    }
    pub fn at(self: Group, index: usize) Rule {
        const r = self.records[index * 18..][0..18];
        return .{
            .source = word(r, 0),
            .target = word(r, 4),
            .dx = @bitCast(r[2]),
            .dy = @bitCast(r[3]),
            .flags = r[8],
            .next = word(r, 10),
            .conditions = .{
                .{ .code = r[7], .argument = @bitCast(word(r, 12)) },
                .{ .code = r[6], .argument = @bitCast(word(r, 14)) },
            },
            .effect = .{ .code = r[9], .argument = @bitCast(word(r, 16)) },
        };
    }
};
pub fn group(data: []const u8, index: u16) !Group {
    if (data.len < 2) return error.TruncatedRuleDirectory;
    const count = word(data, 0);
    const body = data[2..];
    if (count > 256 or
        index >= count or
        @as(usize, count) * 4 > body.len) {
        return error.InvalidRuleDirectory;
    }
    const offset = std.mem.readInt(u32, body[@as(usize, index) * 4..][0..4], .little);
    if (offset < @as(usize, count) * 4 or
        offset > body.len or
        body.len - offset < 2) {
        return error.InvalidRuleOffset;
    }
    const bytes = @as(usize, word(body, offset)) * 18;
    if (bytes > body.len - offset - 2) return error.TruncatedRules;
    return .{ .records = body[offset + 2..][0..bytes] };
}
fn word(data: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, data[offset..][0..2], .little);
}

test "rules validate their directory and record extent before semantic import" {
    var data: [26]u8 = @splat(0);
    data[0] = 1;
    data[2] = 4;
    data[6] = 1;
    data[8] = 7;
    data[20] = 255;
    data[21] = 255;
    const g = try group(&data, 0);
    try std.testing.expectEqual(@as(usize, 1), g.count());
    try std.testing.expectEqual(@as(u16, 7), g.at(0).source);
    try std.testing.expectEqual(@as(i16, -1), g.at(0).conditions[0].argument);
    try std.testing.expectError(error.TruncatedRules, group(data[0..25], 0));
    data[2] = 0;
    try std.testing.expectError(error.InvalidRuleOffset, group(&data, 0));
}
