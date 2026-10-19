//! The save slots' page (PLAN GS-5): the quick slot and eight others, each with its level and
//! play time, and under them the selected one's picture and date. Choosing a slot saves into it,
//! asking first over a save, or loads it; a save of another version or level shape is shown and
//! not loaded. The game reads the slots, draws the picture and saves or loads.
//!
//! The page ends when it sets `outcome`. Game reads it and sets it back to null; the title
//! scene does the same for `back` on its LOAD page.
const std = @import("std");
const input = @import("../input.zig");
const save = @import("../save.zig");
const font = @import("../content/font.zig");
const text = @import("../render/text.zig");
const content_level = @import("../content/level.zig");
const step_clock = @import("../step_clock.zig");

pub const Mode = enum { save, load };
/// The quick slot, then the eight others. Row 0 is QUICK, and row r is SAVE r.
pub const row_count = 1 + save.slot_count;
pub const Outcome = union(enum) {
    back,
    chosen: usize,
};

/// Where the selected save's picture goes on the page.
pub const picture_x = 16;
pub const picture_y = 158;

/// The storage name of row `row`: QUICK for row 0, SAVE r for row r. `save.slotName` counts
/// its slots from 0 (slot 0 is SAVE1), so row r gives it r - 1.
pub fn slotName(row: usize, buffer: *[8]u8) []const u8 {
    return if (row == 0) save.quick_slot else save.slotName(row - 1, buffer);
}

pub const Page = struct {
    mode: Mode,
    selection: usize = 0,
    /// Asking whether to save over the selected slot's save.
    confirming: bool = false,
    /// The selected save cannot be loaded; why shows until another press.
    refused: bool = false,
    outcome: ?Outcome = null,

    /// Up and down choose a row, a button chooses it, Escape goes back (or answers no).
    pub fn press(self: *Page, action: input.Action, slots: []const save.Slot) void {
        self.refused = false;
        if (self.confirming) {
            switch (action) {
                .use, .gun, .act => {
                    self.confirming = false;
                    self.outcome = .{ .chosen = self.selection };
                },
                .pause => self.confirming = false,
                else => {},
            }
            return;
        }
        switch (action) {
            .up => self.selection = (self.selection + row_count - 1) % row_count,
            .down => self.selection = (self.selection + 1) % row_count,
            .use, .gun, .act => self.choose(slots[self.selection]),
            .pause => self.outcome = .back,
            .left, .right, .inventory => {},
        }
    }

    /// A pad's START, through `game_options.Menu.back`: no to the question, or back.
    pub fn back(self: *Page) void {
        self.refused = false;
        if (self.confirming) {
            self.confirming = false;
        } else {
            self.outcome = .back;
        }
    }

    fn choose(self: *Page, slot: save.Slot) void {
        switch (self.mode) {
            .save => if (slot == .empty) {
                self.outcome = .{ .chosen = self.selection };
            } else {
                self.confirming = true;
            },
            .load => if (slot == .save and slot.save.loadable) {
                self.outcome = .{ .chosen = self.selection };
            } else {
                self.refused = slot != .empty;
            },
        }
    }

    /// The page in `style` (the selected row in `selected`), over what `pixels` hold.
    pub fn draw(
        self: Page,
        pixels: []u8,
        glyphs: *const font.Font,
        slots: []const save.Slot,
        style: text.Style,
        selected: text.Style,
    ) !void {
        const title = if (self.mode == .save) "SAVE GAME" else "LOAD GAME";
        try text.draw(pixels, 256, 224, glyphs, title, center(title), 12, style);
        for (slots[0..row_count], 0..) |slot, row| {
            const y: i32 = 30 + @as(i32, @intCast(row)) * 14;
            const row_style = if (row == self.selection) selected else style;
            var name: [8]u8 = undefined;
            const label = if (row == 0)
                "QUICK"
            else
                std.fmt.bufPrint(&name, "{d}", .{ row }) catch unreachable;
            try text.draw(pixels, 256, 224, glyphs, label, 16, y, row_style);
            var time: [16]u8 = undefined;
            const what: []const u8, const when: []const u8 = switch (slot) {
                .empty => .{ "- EMPTY -", "" },
                .other_version => .{ "OTHER VERSION", "" },
                .broken => .{ "UNREADABLE", "" },
                .save => |s| .{ levelName(s.level), playTime(s.play_walks, &time) },
            };
            try text.draw(pixels, 256, 224, glyphs, what, 64, y, row_style);
            try text.draw(pixels, 256, 224, glyphs, when, 184, y, row_style);
        }
        const chosen = slots[self.selection];
        if (chosen == .save) {
            try text.draw(pixels, 256, 224, glyphs, chosen.save.date, 96, 166, style);
        }
        const status: []const u8 = if (self.confirming)
            "SAVE OVER IT?"
        else if (self.refused) switch (chosen) {
            .other_version => "ANOTHER VERSION",
            .broken => "IT DOES NOT READ",
            else => "OTHER GAME DATA",
        } else "";
        try text.draw(pixels, 256, 224, glyphs, status, 96, 182, selected);
    }
};

fn center(label: []const u8) i32 {
    return @divTrunc(256 - @as(i32, @intCast(label.len)) * 8, 2);
}

pub fn levelName(level: content_level.Id) []const u8 {
    return switch (level) {
        .jungle => "JUNGLE",
        .city => "NEW WASHINGTON",
        .tower => "DEATH TOWER",
        .earth_city => "EARTH",
        .spaceport => "SPACEPORT",
        .alien_surface => "ALIEN SURFACE",
        .alien_base => "ALIEN BASE",
    };
}

/// Play time as hours, minutes and seconds: a walk takes two ticks of the original's timer.
pub fn playTime(walks: u64, buffer: *[16]u8) []const u8 {
    const seconds = walks * 2 * step_clock.counts_per_tick / step_clock.timer_hz;
    return std.fmt.bufPrint(buffer, "{d}:{d:0>2}:{d:0>2}", .{
        seconds / 3600,
        seconds / 60 % 60,
        seconds % 60,
    }) catch unreachable;
}

test "the page chooses slots: empty ones at once, over a save after asking, never a save it cannot load" {
    var slots: [row_count]save.Slot = @splat(.empty);
    slots[1] = .{
        .save = .{ .level = .city, .play_walks = 0, .date = "", .picture = null, .loadable = true },
    };
    slots[2] = .{
        .save = .{
            .level = .city,
            .play_walks = 0,
            .date = "",
            .picture = null,
            .loadable = false,
        },
    };
    slots[3] = .other_version;

    var saving: Page = .{ .mode = .save };
    saving.press(.use, &slots);
    try std.testing.expectEqual(@as(?Outcome, .{ .chosen = 0 }), saving.outcome);
    saving = .{ .mode = .save };
    saving.press(.down, &slots);
    saving.press(.act, &slots);
    try std.testing.expect(saving.confirming and saving.outcome == null);
    saving.back();
    try std.testing.expect(!saving.confirming and saving.outcome == null);
    saving.press(.gun, &slots);
    saving.press(.use, &slots);
    try std.testing.expectEqual(@as(?Outcome, .{ .chosen = 1 }), saving.outcome);

    var loading: Page = .{ .mode = .load };
    loading.press(.up, &slots);
    try std.testing.expectEqual(@as(usize, row_count - 1), loading.selection);
    loading.press(.use, &slots);
    try std.testing.expect(loading.outcome == null and !loading.refused);
    loading.selection = 2;
    loading.press(.use, &slots);
    try std.testing.expect(loading.refused and loading.outcome == null);
    loading.selection = 3;
    loading.press(.use, &slots);
    try std.testing.expect(loading.refused);
    loading.selection = 1;
    loading.press(.use, &slots);
    try std.testing.expectEqual(@as(?Outcome, .{ .chosen = 1 }), loading.outcome);
    loading = .{ .mode = .load };
    loading.press(.pause, &slots);
    try std.testing.expectEqual(@as(?Outcome, .back), loading.outcome);
}

test "play time and slot names" {
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0:00:00", playTime(0, &buffer));
    // 35 walks a second, about.
    try std.testing.expectEqualStrings("1:00:00", playTime(3600 * 35045 / 1000 + 1, &buffer));
    var name: [8]u8 = undefined;
    try std.testing.expectEqualStrings("QUICK", slotName(0, &name));
    try std.testing.expectEqualStrings("SAVE8", slotName(8, &name));
}
