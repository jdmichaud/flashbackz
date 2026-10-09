//! Inventory navigation and presentation. The visible selection precedes the next input
//! transition; closing chooses the last displayed item, including while showing the score.
const std = @import("std");
const sprite = @import("../content/sprite.zig");
const font_mod = @import("../content/font.zig");
const sprites = @import("../render/sprite.zig");
const text = @import("../render/text.zig");
const platform = @import("../platform.zig");

pub const Input = struct {
    right: bool = false,
    left: bool = false,
    up: bool = false,
    down: bool = false,
    score: bool = false,
    close: bool = false,
};
const Directions = struct {
    right: bool = false,
    left: bool = false,
    up: bool = false,
    down: bool = false,
};

/// Navigation consumes a key make, including a repeated key-down event. Score keys remain
/// held. Mixed axes retain the preceding sampled directions, as in gameplay input.
pub const Keys = struct {
    directions: Directions = .{},
    previous: Directions = .{},
    left_shift: bool = false,
    right_shift: bool = false,
    space: bool = false,
    enter: bool = false,
    tab: bool = false,

    /// Other keys, P and the function keys included, do nothing here (P's film pause is the
    /// game's).
    pub fn key(self: *Keys, code: platform.Key, down: bool) void {
        switch (code) {
            .right => self.directions.right = down,
            .left => self.directions.left = down,
            .up => self.directions.up = down,
            .down => self.directions.down = down,
            .left_shift => self.left_shift = down,
            .right_shift => self.right_shift = down,
            .space => self.space = down,
            .enter => self.enter = down,
            .tab => self.tab = down,
            else => {},
        }
    }

    pub fn sample(self: *Keys) Input {
        const d = self.directions;
        if (!((d.left or d.right) and (d.up or d.down))) self.previous = d;
        const selected = self.previous;
        if (selected.right) self.directions.right = false else if (selected.left) self.directions.left = false else if (selected.up) self.directions.up = false else if (selected.down) self.directions.down = false;
        return .{
            .right = selected.right,
            .left = selected.left,
            .up = selected.up,
            .down = selected.down,
            .score = self.left_shift or self.right_shift or self.space or self.enter,
            .close = self.tab,
        };
    }
};
pub const View = union(enum) { items: usize, score };
pub const Result = union(enum) { stay, choose: usize };
pub const Entry = struct { icon: *const sprite.Frame, label: []const u8, quantity: ?u16 };
pub const Artwork = struct {
    background: *const sprite.Frame,
    marker: *const sprite.Frame,
    previous_page: *const sprite.Frame,
    next_page: *const sprite.Frame,
    font: *const font_mod.Font,
    level_label: []const u8,
};

pub const Menu = struct {
    count: usize,
    cursor: usize = 0,
    last_displayed: usize = 0,
    score_next: bool = false,
    view: View = .{ .items = 0 },

    pub fn init(count: usize) !Menu {
        if (count == 0) return error.EmptyInventory;
        return .{ .count = count };
    }

    pub fn poll(self: *Menu, input: Input) Result {
        if (input.close) return .{ .choose = self.last_displayed };
        self.view = if (self.score_next) .score else .{ .items = self.cursor };
        if (!self.score_next) self.last_displayed = self.cursor;
        if (input.right) {
            if (self.cursor % 4 < 3 and self.cursor + 1 < self.count) self.cursor += 1;
        } else if (input.left) {
            if (self.cursor % 4 != 0) self.cursor -= 1;
        } else if (input.up) {
            if (self.cursor >= 4) self.cursor -= 4;
        } else if (input.down) {
            if (self.cursor / 4 < (self.count - 1) / 4) self.cursor = @min(self.cursor + 4, self.count - 1);
        }
        self.score_next = input.score;
        return .stay;
    }

    pub fn draw(
        self: Menu,
        art: Artwork,
        entries: []const Entry,
        score: u32,
        pixels: []u8,
        width: u16,
        height: u16,
    ) !void {
        if (entries.len != self.count) return error.InventoryViewMismatch;
        try sprites.draw(
            pixels,
            width,
            height,
            art.background,
            56,
            140,
            .{ .palette_bank = 15, .foreground = .overwrite },
        );
        switch (self.view) {
            .items => |selected| {
                const start = selected / 4 * 4;
                for (entries[start..@min(start + 4, entries.len)], 0..) |entry, column| {
                    const x = 72 + @as(i32, @intCast(column)) * 32;
                    try sprites.draw(
                        pixels,
                        width,
                        height,
                        entry.icon,
                        x,
                        157,
                        .{ .palette_bank = 10, .foreground = .overwrite },
                    );
                    if (start + column == selected) {
                        try sprites.draw(
                            pixels,
                            width,
                            height,
                            art.marker,
                            x,
                            157,
                            .{ .palette_bank = 10, .foreground = .overwrite },
                        );
                        try centered(
                            pixels,
                            width,
                            height,
                            art.font,
                            entry.label,
                            0,
                            256,
                            189,
                            0xed,
                        );
                        if (entry.quantity) |quantity| {
                            var buffer: [5]u8 = undefined;
                            const label = try std.fmt.bufPrint(&buffer, "{d}", .{quantity});
                            try centered(pixels, width, height, art.font, label, 0, 256, 197, 0xed);
                        }
                    }
                }
                if (start != 0) try sprites.draw(
                    pixels,
                    width,
                    height,
                    art.previous_page,
                    120,
                    143,
                    .{ .palette_bank = 10, .foreground = .overwrite },
                );
                if (start / 4 < (entries.len - 1) / 4) try sprites.draw(
                    pixels,
                    width,
                    height,
                    art.next_page,
                    120,
                    176,
                    .{ .palette_bank = 10, .foreground = .overwrite },
                );
            },
            .score => {
                var buffer: [14]u8 = undefined;
                const label = try std.fmt.bufPrint(&buffer, "SCORE {d:0>8}", .{score % 100000000});
                try centered(pixels, width, height, art.font, label, 72, 114, 158, 0xe5);
                try centered(pixels, width, height, art.font, art.level_label, 72, 114, 166, 0xe5);
            },
        }
    }
};

fn centered(
    pixels: []u8,
    width: u16,
    height: u16,
    font: *const font_mod.Font,
    label: []const u8,
    left: i32,
    span: i32,
    y: i32,
    color: u8,
) !void {
    if (label.len > 256) return error.InventoryLabelTooLong;
    const x = left + @divTrunc(span - @as(i32, @intCast(label.len)) * 8, 2);
    // Original interface text starts on a four-pixel boundary after centering. Preserve
    // that layout rule here; the general glyph renderer keeps ordinary pixel coordinates.
    const aligned_x = @divFloor(x, 4) * 4;
    try text.draw(
        pixels,
        width,
        height,
        font,
        label,
        aligned_x,
        y,
        .{ .foreground = color, .shadow = 0xe2, .palette_bank = 14 },
    );
}

test "vertical navigation preserves the column and clamps a partial last page" {
    var menu = try Menu.init(10);
    for (0..3) |_| _ = menu.poll(.{ .right = true });
    try std.testing.expectEqual(@as(usize, 3), menu.cursor);
    _ = menu.poll(.{ .down = true });
    try std.testing.expectEqual(@as(usize, 7), menu.cursor);
    _ = menu.poll(.{ .down = true });
    try std.testing.expectEqual(@as(usize, 9), menu.cursor);
    _ = menu.poll(.{ .up = true });
    try std.testing.expectEqual(@as(usize, 5), menu.cursor);
    _ = menu.poll(.{ .left = true, .up = true });
    try std.testing.expectEqual(@as(usize, 4), menu.cursor);
}

test "closing commits the displayed item and score follows held input one poll later" {
    var menu = try Menu.init(3);
    _ = menu.poll(.{ .right = true });
    try std.testing.expectEqual(@as(usize, 0), menu.view.items);
    try std.testing.expectEqual(@as(usize, 0), menu.poll(.{ .close = true }).choose);
    _ = menu.poll(.{ .score = true });
    try std.testing.expectEqual(@as(usize, 1), menu.view.items);
    _ = menu.poll(.{ .right = true, .score = true });
    try std.testing.expect(menu.view == .score);
    _ = menu.poll(.{});
    try std.testing.expect(menu.view == .score);
    try std.testing.expectEqual(@as(usize, 1), menu.poll(.{ .close = true }).choose);
    _ = menu.poll(.{});
    try std.testing.expectEqual(@as(usize, 2), menu.view.items);
    try std.testing.expectError(error.EmptyInventory, Menu.init(0));
}

test "centered score text retains the interface's four-pixel placement grid" {
    var raw: [52 * 32]u8 = @splat(0);
    raw[('S' - 32) * 32] = 0xf0;
    var font = try font_mod.decode(std.testing.allocator, &raw);
    defer font.deinit();
    var pixels: [256 * 224]u8 = @splat(0);
    try centered(&pixels, 256, 224, &font, "SCORE 00000000", 72, 114, 158, 0xe5);
    try std.testing.expectEqual(@as(u8, 0xe5), pixels[158 * 256 + 72]);
    try std.testing.expectEqual(@as(u8, 0), pixels[158 * 256 + 73]);
}

test "navigation consumes makes and mixed axes retain the preceding sample" {
    var keys: Keys = .{};
    keys.key(.right, true);
    try std.testing.expect(keys.sample().right);
    keys.key(.left, true);
    keys.key(.up, true);
    try std.testing.expect(keys.sample().right);
    keys.key(.up, false);
    try std.testing.expect(keys.sample().left);
    try std.testing.expect(!keys.sample().left);
    // An explicit repeated make re-arms navigation without needing a release.
    keys.key(.left, true);
    try std.testing.expect(keys.sample().left);
    keys.key(.left_shift, true);
    keys.key(.right_shift, true);
    keys.key(.left_shift, false);
    try std.testing.expect(keys.sample().score);
    keys.key(.right_shift, false);
    try std.testing.expect(!keys.sample().score);
    keys.key(.left_ctrl, true);
    try std.testing.expect(!keys.sample().score);
    keys.key(.space, true);
    try std.testing.expect(keys.sample().score);
    for ([_]platform.Key{ .p, .f1, .f2, .f3, .escape }) |code| keys.key(code, true);
    try std.testing.expect(keys.sample().score);
}
