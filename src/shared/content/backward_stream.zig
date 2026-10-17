//! Bounded backward bitstream import used by the installation archives (ABA) and the collision
//! (CT), object art (MBK), room (LEV) and tile bank (BNQ) files. Bytes and bit refill order
//! reproduce the original codec; the result is owned content, not a simulated DOS buffer.
const std = @import("std");

const Bits = struct {
    bytes: []const u8,
    cursor: usize,
    word: u32,
    checksum: u32,

    fn take(self: *Bits, count: u5) !u32 {
        var result: u32 = 0;
        for (0..count) |_| {
            var bit = self.word & 1;
            self.word >>= 1;
            if (self.word == 0) {
                if (self.cursor < 4) return error.TruncatedBitstream;
                self.cursor -= 4;
                const refill = std.mem.readInt(u32, self.bytes[self.cursor..][0..4], .big);
                self.checksum ^= refill;
                bit = refill & 1;
                self.word = 0x80000000 | (refill >> 1);
            }
            result = (result << 1) | bit;
        }
        return result;
    }
};

const Command = union(enum) {
    literal: usize,
    reference: struct { length: usize, distance: usize },

    fn read(bits: *Bits) !Command {
        const prefix = try bits.take(2);
        if (prefix == 0) return .{ .literal = try bits.take(3) + 1 };
        if (prefix == 1) return .{ .reference = .{ .length = 2, .distance = try bits.take(8) } };
        const kind = ((prefix & 1) << 1) | try bits.take(1);
        if (kind == 3) return .{ .literal = try bits.take(8) + 9 };
        if (kind == 2) {
            return .{
                .reference = .{ .length = try bits.take(8) + 1, .distance = try bits.take(12) },
            };
        }
        return .{
            .reference = .{ .length = kind + 3, .distance = try bits.take(@intCast(kind + 9)) },
        };
    }
};

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, maximum: usize) ![]u8 {
    if (bytes.len < 12 or bytes.len % 4 != 0) return error.InvalidBitstreamLength;
    const cursor = bytes.len - 12;
    const initial_word = std.mem.readInt(u32, bytes[cursor..][0..4], .big);
    const checksum = std.mem.readInt(u32, bytes[cursor + 4..][0..4], .big);
    const size = std.mem.readInt(u32, bytes[cursor + 8..][0..4], .big);
    if (size > maximum) return error.ExpandedContentTooLarge;
    var bits: Bits = .{
        .bytes = bytes,
        .cursor = cursor,
        .word = initial_word,
        .checksum = checksum ^ initial_word,
    };
    const output = try allocator.alloc(u8, size);
    errdefer allocator.free(output);
    var remaining = output.len;
    while (remaining != 0) {
        switch (try Command.read(&bits)) {
            .literal => |length| {
                if (length > remaining) return error.ExpandedContentOverflow;
                for (0..length) |_| {
                    remaining -= 1;
                    output[remaining] = @intCast(try bits.take(8));
                }
            },
            .reference => |reference| {
                if (reference.length > remaining) return error.ExpandedContentOverflow;
                if (reference.distance == 0) return error.InvalidBackReference;
                for (0..reference.length) |_| {
                    remaining -= 1;
                    if (reference.distance >= output.len - remaining) {
                        return error.InvalidBackReference;
                    }
                    output[remaining] = output[remaining + reference.distance];
                }
            },
        }
    }
    if (bits.checksum != 0) return error.InvalidBitstreamChecksum;
    return output;
}

test "backward literals cross refill boundaries and overlapping references repeat written bytes" {
    const allocator = std.testing.allocator;
    // Synthetic bitstreams, generated from literal and distance-one commands, not game data.
    const literals = [_]u8{
        0x86,
        0x46,
        0xc6,
        0x26,
        0xa6,
        0x66,
        0xe6,
        0x16,
        0,
        0,
        0,
        0x3c,
        0x20,
        0x20,
        0x20,
        0x0c,
        0,
        0,
        0,
        8,
    };
    const text = try decode(allocator, &literals, 8);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("abcdefgh", text);
    const repeated = [_]u8{ 3, 0, 0x30, 0x40, 3, 0, 0x30, 0x40, 0, 0, 0, 4 };
    const copies = try decode(allocator, &repeated, 4);
    defer allocator.free(copies);
    try std.testing.expectEqualStrings("AAAA", copies);
}

test "backward stream limits and malformed input fail without leaking output" {
    const allocator = std.testing.allocator;
    var input: [12]u8 = @splat(0);
    input[11] = 1;
    try std.testing.expectError(error.ExpandedContentTooLarge, decode(allocator, &input, 0));
    try std.testing.expectError(error.TruncatedBitstream, decode(allocator, &input, 1));
    try std.testing.expectError(error.InvalidBitstreamLength, decode(allocator, input[0..11], 1));
    input[11] = 0;
    input[7] = 1;
    try std.testing.expectError(error.InvalidBitstreamChecksum, decode(allocator, &input, 1));
    const zero_distance = [_]u8{ 0, 0, 4, 2, 0, 0, 4, 2, 0, 0, 0, 2 };
    const bad_distance = [_]u8{ 0, 0, 6, 2, 0, 0, 6, 2, 0, 0, 0, 2 };
    const overflow = [_]u8{ 0, 0, 0, 0x3c, 0, 0, 0, 0x3c, 0, 0, 0, 1 };
    try std.testing.expectError(error.InvalidBackReference, decode(allocator, &zero_distance, 2));
    try std.testing.expectError(error.InvalidBackReference, decode(allocator, &bad_distance, 2));
    try std.testing.expectError(error.ExpandedContentOverflow, decode(allocator, &overflow, 1));
}
