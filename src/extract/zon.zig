//! A small writer for readable, zig-fmt-style ZON: one field per line, trailing commas.
const std = @import("std");

pub const Writer = struct {
    out: *std.Io.Writer,
    depth: usize = 0,

    pub fn line(self: *Writer, comptime format: []const u8, arguments: anytype) !void {
        try self.out.splatByteAll(' ', self.depth * 4);
        try self.out.print(format ++ "\n", arguments);
    }

    /// Start a field or element that opens a nested literal: `.name = .{` or `.{`.
    pub fn open(self: *Writer, name: ?[]const u8) !void {
        try self.out.splatByteAll(' ', self.depth * 4);
        if (name) |n| {
            try self.out.print("{f} = .{{\n", .{identifier(n)});
        } else try self.out.writeAll(".{\n");
        self.depth += 1;
    }

    pub fn close(self: *Writer) !void {
        self.depth -= 1;
        try self.out.splatByteAll(' ', self.depth * 4);
        try self.out.writeAll(if (self.depth == 0) "}\n" else "},\n");
    }
};

/// `.name` for a plain identifier, otherwise `.@"name"`.
pub fn identifier(name: []const u8) Identifier {
    return .{ .name = name };
}

pub const Identifier = struct {
    name: []const u8,
    pub fn format(self: Identifier, out: *std.Io.Writer) std.Io.Writer.Error!void {
        if (isPlainIdentifier(self.name)) return out.print(".{s}", .{self.name});
        try out.writeAll(".@");
        try writeString(out, self.name);
    }
};

/// A string literal with Zig escapes.
pub fn string(text: []const u8) Quoted {
    return .{ .text = text };
}

pub const Quoted = struct {
    text: []const u8,
    pub fn format(self: Quoted, out: *std.Io.Writer) std.Io.Writer.Error!void {
        try writeString(out, self.text);
    }
};

fn writeString(out: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    try out.writeByte('"');
    for (text) |c| switch (c) {
        '"' => try out.writeAll("\\\""),
        '\\' => try out.writeAll("\\\\"),
        '\n' => try out.writeAll("\\n"),
        0x20...0x21, 0x23...0x5b, 0x5d...0x7e => try out.writeByte(c),
        else => try out.print("\\x{x:0>2}", .{c}),
    };
    try out.writeByte('"');
}

pub fn isPlainIdentifier(name: []const u8) bool {
    if (name.len == 0 or std.ascii.isDigit(name[0])) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return std.zig.Token.getKeyword(name) == null and !std.zig.isPrimitive(name);
}

/// Lowercase letters and digits joined by single underscores, for names made from labels.
pub fn sanitize(buffer: []u8, text: []const u8) []const u8 {
    var length: usize = 0;
    var gap = false;
    for (text) |c| {
        if (length == buffer.len) break;
        if (std.ascii.isAlphanumeric(c)) {
            if (gap and length != 0) {
                buffer[length] = '_';
                length += 1;
                if (length == buffer.len) break;
            }
            buffer[length] = std.ascii.toLower(c);
            length += 1;
            gap = false;
        } else gap = true;
    }
    return buffer[0..length];
}

test "identifiers that are not plain names are quoted" {
    var buffer: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try out.print(
        "{f} {f} {f}",
        .{ identifier("watching"), identifier("type"), identifier("2nd") },
    );
    try std.testing.expectEqualStrings(".watching .@\"type\" .@\"2nd\"", out.buffered());
}

test "strings escape quotes, backslashes and control bytes" {
    var buffer: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try out.print("{f}", .{string("a\"b\\c\x01")});
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\x01\"", out.buffered());
}

test "labels become lowercase names" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("work_permit", sanitize(&buffer, "WORK PERMIT"));
    try std.testing.expectEqualStrings("id_card", sanitize(&buffer, " ID-CARD "));
}
