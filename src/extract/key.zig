//! A behavior's structural key: a digest of its rules with state and message numbers replaced by
//! their order of first appearance. Copies of one behavior that use different animations or
//! message values share a key, so one overlay entry names them all.
const std = @import("std");
const rule_table = @import("rule_table.zig");
const codes = @import("codes.zig");

pub const Key = [16]u8;

pub fn compute(group: rule_table.Group) Key {
    var states: Renumbering = .{};
    var messages: Renumbering = .{};
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (0..group.count()) |index| {
        const rule = group.at(index);
        var encoded: [18]u8 = undefined;
        std.mem.writeInt(u16, encoded[0..2], states.of(rule.source), .little);
        std.mem.writeInt(u16, encoded[2..4], states.of(rule.target), .little);
        encoded[4] = @bitCast(rule.dx);
        encoded[5] = @bitCast(rule.dy);
        encoded[6] = rule.flags;
        std.mem.writeInt(u16, encoded[7..9], rule.next, .little);
        for (
            [_]rule_table.Operation{ rule.conditions[0], rule.conditions[1], rule.effect },
            0..,
        ) |operation, slot| {
            const raw: u16 = @bitCast(operation.argument);
            const argument = if (carriesMessage(operation.code)) messages.of(raw) else raw;
            encoded[9 + slot * 3] = operation.code;
            std.mem.writeInt(u16, encoded[10 + slot * 3..][0..2], argument, .little);
        }
        hash.update(&encoded);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest[0..8].*, .lower);
}

fn carriesMessage(code: u8) bool {
    const known = codes.lookup(code) orelse return false;
    return switch (known.argument) {
        .message, .send_to_link => true,
        else => false,
    };
}

/// Numbers in order of first appearance; a small table suffices for one rule group.
const Renumbering = struct {
    seen: [512]u16 = undefined,
    count: u16 = 0,
    fn of(self: *Renumbering, value: u16) u16 {
        const known = self.seen[0..self.count];
        if (std.mem.indexOfScalar(u16, known, value)) |index| return @intCast(index);
        if (self.count == self.seen.len) return 0xffff;
        self.seen[self.count] = value;
        self.count += 1;
        return self.count - 1;
    }
};

fn row(source: u16, target: u16, code: u8, argument: u16) [18]u8 {
    var r: [18]u8 = @splat(0);
    std.mem.writeInt(u16, r[0..2], source, .little);
    std.mem.writeInt(u16, r[4..6], target, .little);
    r[7] = code;
    std.mem.writeInt(u16, r[12..14], argument, .little);
    return r;
}

test "renumbered states and messages share a key; other arguments do not" {
    const a: rule_table.Group = .{ .records = &(row(768, 767, 34, 20) ++ row(767, 768, 97, 5)) };
    const b: rule_table.Group = .{ .records = &(row(900, 901, 34, 31) ++ row(901, 900, 97, 5)) };
    const c: rule_table.Group = .{ .records = &(row(900, 901, 34, 31) ++ row(901, 900, 97, 6)) };
    try std.testing.expectEqualStrings(&compute(a), &compute(b));
    try std.testing.expect(!std.mem.eql(u8, &compute(a), &compute(c)));
}
