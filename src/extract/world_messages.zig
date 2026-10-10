//! Convert the edition's message directory and formatting bytes into owned dialogue pages.
const std = @import("std");
/// A world message: pages of lines, each with its ink.
pub const Line = struct { text: []const u8, ink: u8 };
pub const Page = struct { lines: []const Line };
pub const Message = struct { pages: []const Page };
pub const Id = enum(u16) { _ };
const flashbackz = @import("flashbackz");
const floppy_interface = flashbackz.content.floppy_interface;
const platform = flashbackz.platform;
pub const Assets = struct {
    allocator: std.mem.Allocator,
    messages: []Message,
    pub fn deinit(self: *Assets) void {
        for (self.messages) |message| releaseMessage(self.allocator, message);
        self.allocator.free(self.messages);
    }
    pub fn get(self: Assets, id: Id) !Message {
        if (@backingInt(id) >= self.messages.len) return error.UnknownWorldMessage;
        return self.messages[@backingInt(id)];
    }
};
fn releasePage(allocator: std.mem.Allocator, page: Page) void {
    for (page.lines) |line| allocator.free(line.text);
    allocator.free(page.lines);
}
fn releaseMessage(allocator: std.mem.Allocator, message: Message) void {
    for (message.pages) |page| releasePage(allocator, page);
    allocator.free(message.pages);
}
fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Message {
    var pages: std.ArrayList(Page) = .empty;
    errdefer {
        for (pages.items) |page| releasePage(allocator, page);
        pages.deinit(allocator);
    }
    var lines: std.ArrayList(Line) = .empty;
    errdefer {
        for (lines.items) |line| allocator.free(line.text);
        lines.deinit(allocator);
    }
    var cursor: usize = 0;
    var ink: u8 = 0xe8;
    while (true) {
        if (cursor >= bytes.len) return error.UnterminatedWorldMessage;
        if (bytes[cursor] == 0xff) {
            if (bytes.len - cursor < 3) return error.TruncatedMessageInk;
            ink = bytes[cursor + 1]; // The original glyph renderer uses the low byte only.
            cursor += 3;
        }
        const start = cursor;
        while (cursor < bytes.len and
            bytes[cursor] != 0 and
            bytes[cursor] != 10 and
            bytes[cursor] != 11) : (cursor += 1)
        {}
        if (cursor >= bytes.len) return error.UnterminatedWorldMessage;
        if (lines.items.len >= 32 or cursor - start > 256) return error.MessageTooLarge;
        const text = try allocator.dupe(u8, bytes[start..cursor]);
        lines.append(allocator, .{ .text = text, .ink = ink }) catch |err| {
            allocator.free(text);
            return err;
        };
        const separator = bytes[cursor];
        cursor += 1;
        if (separator == 10) continue;
        const owned = try lines.toOwnedSlice(allocator);
        pages.append(allocator, .{ .lines = owned }) catch |err| {
            releasePage(allocator, .{ .lines = owned });
            return err;
        };
        if (separator == 0) break;
        if (pages.items.len >= 64) return error.MessageTooLarge;
    }
    return .{ .pages = try pages.toOwnedSlice(allocator) };
}
pub fn decode(allocator: std.mem.Allocator, table: []const u8) !Assets {
    if (table.len < 2) return error.TruncatedMessageDirectory;
    const first = std.mem.readInt(u16, table[0..2], .little);
    if (first < 2 or
        first % 2 != 0 or
        first > table.len or
        first / 2 > 256) return error.InvalidMessageDirectory;
    var messages: std.ArrayList(Message) = .empty;
    errdefer {
        for (messages.items) |message| releaseMessage(allocator, message);
        messages.deinit(allocator);
    }
    for (0..first / 2) |index| {
        const offset = std.mem.readInt(u16, table[index * 2 ..][0..2], .little);
        if (offset < first or offset >= table.len) return error.InvalidMessageOffset;
        const message = try parse(allocator, table[offset..]);
        messages.append(allocator, message) catch |err| {
            releaseMessage(allocator, message);
            return err;
        };
    }
    return .{ .allocator = allocator, .messages = try messages.toOwnedSlice(allocator) };
}
pub fn load(allocator: std.mem.Allocator, source: platform.AssetSource) !Assets {
    const image = try floppy_interface.loadImage(allocator, source);
    defer allocator.free(image);
    // The message table sits at DS:0x13e9.
    return decode(allocator, image[floppy_interface.data_segment + 0x13e9 ..]);
}
test "message pages retain ink changes and reject truncated escapes" {
    const a = std.testing.allocator;
    var content = try decode(a, &.{ 2, 0, 'A', 10, 'B', 11, 255, 235, 236, 'C', 0 });
    defer content.deinit();
    try std.testing.expectEqual(@as(usize, 2), content.messages[0].pages.len);
    try std.testing.expectEqual(@as(u8, 0xe8), content.messages[0].pages[0].lines[1].ink);
    try std.testing.expectEqual(@as(u8, 235), content.messages[0].pages[1].lines[0].ink);
    try std.testing.expectError(error.TruncatedMessageInk, decode(a, &.{ 2, 0, 255, 235 }));
    try std.testing.expectError(error.InvalidMessageOffset, decode(a, &.{ 2, 0 }));
}
