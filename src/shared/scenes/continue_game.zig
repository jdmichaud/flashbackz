//! Continue/Abort presentation and bounded display-clock polling after a defeat.
const std = @import("std");
const platform = @import("../platform.zig");
const artwork = @import("../content/continue_artwork.zig");
const palette = @import("../content/palette.zig");
const text = @import("../render/text.zig");
const timing = @import("../step_clock.zig");
const confirm_keys = [_]platform.Key{
    .enter,
    .space,
    .tab,
    .left_shift,
    .right_shift,
    .left_ctrl,
    .right_ctrl,
};
pub const Choice = enum { retry, abort };
pub const View = struct { choice: Choice = .retry, seconds: i16 = 10, pulse: u8 = 0 };
pub const Menu = struct {
    allocator: std.mem.Allocator,
    score: u32,
    choice: Choice = .retry,
    seconds: i16 = 10,
    pulse: u8 = 0,
    brightening: bool = true,
    view: View = .{},
    outcome: ?Choice = null,
    activation_key: ?platform.Key = null,
    cancel_pending: bool = false,
    up_pending: bool = false,
    down_pending: bool = false,
    held_confirmation: [confirm_keys.len]bool = @splat(false),
    clock: ?timing.Clock = null,
    last_second_tick: u64 = 0,
    events: std.ArrayList(platform.Event) = .empty,
    pub fn init(allocator: std.mem.Allocator, score: u32) Menu {
        return .{ .allocator = allocator, .score = score };
    }
    pub fn deinit(self: *Menu) void {
        self.events.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn event(self: *Menu, input: platform.Event) !void {
        switch (input.payload) {
            .key_up, .key_down, .focus_lost => {},
            else => return,
        }
        if (self.events.items.len == 128) return error.InputQueueFull;
        try self.events.append(self.allocator, input);
    }
    pub fn update(self: *Menu, now: u64) !void {
        if (self.clock == null) self.clock = try timing.Clock.init(timing.inventory, now);
        var work: usize = 0;
        while (self.clock.?.due(now) and self.outcome == null and work < 8) : (work += 1) {
            const deadline = self.clock.?.deadline();
            while (self.events.items.len != 0 and self.events.items[0].time_ns <= deadline) {
                const input = self.events.orderedRemove(0);
                switch (input.payload) {
                    .key_down, .key_up => |key| {
                        const pressed = input.payload == .key_down;
                        if (key.key == .escape) self.cancel_pending = pressed;
                        if (key.key == .up) self.up_pending = pressed;
                        if (key.key == .down) self.down_pending = pressed;
                        for (confirm_keys, 0..) |candidate, i| if (candidate == key.key) {
                            self.held_confirmation[i] = pressed;
                        };
                    },
                    .focus_lost => {
                        self.cancel_pending = false;
                        self.up_pending = false;
                        self.down_pending = false;
                        @memset(&self.held_confirmation, false);
                    },
                    else => unreachable,
                }
            }
            self.activation_key = null;
            for (confirm_keys, self.held_confirmation) |key, pressed| if (pressed) {
                self.activation_key = key;
                break;
            };
            if (self.seconds < 0 or self.cancel_pending) {
                self.outcome = .abort;
                return;
            }
            if (self.activation_key != null) {
                self.outcome = self.choice;
                return;
            }
            self.view.choice = self.choice;
            self.view.seconds = self.seconds;
            if (self.up_pending) {
                self.choice = .retry;
                self.up_pending = false;
            } else if (self.down_pending) {
                self.choice = .abort;
                self.down_pending = false;
            }
            if (self.pulse >= 61) self.brightening = false;
            if (self.pulse < 2) self.brightening = true;
            self.pulse = if (self.brightening) self.pulse + 2 else self.pulse - 2;
            self.view.pulse = self.pulse;
            const elapsed = deadline - self.clock.?.origin_ns;
            const units = elapsed / std.time.ns_per_s * 1193182 + elapsed % std.time.ns_per_s * 1193182 / std.time.ns_per_s;
            const tick = units / 17024;
            if (tick - self.last_second_tick >= 60) {
                self.seconds -= 1;
                self.last_second_tick = tick;
            }
            self.clock.?.consume();
        }
    }
    pub fn needsCatchup(self: *const Menu, now: u64) bool {
        return self.outcome == null and if (self.clock) |clock| clock.due(now) else false;
    }
    pub fn stateHash(self: *const Menu) u64 {
        var hash = std.hash.Wyhash.init(0);
        hash.update(&.{ @backingInt(self.choice), self.pulse, @intFromBool(self.brightening) });
        hash.update(&std.mem.toBytes(std.mem.nativeToLittle(i16, self.seconds)));
        hash.update(&.{
            @intFromBool(self.cancel_pending),
            @intFromBool(self.up_pending),
            @intFromBool(self.down_pending),
            @backingInt(self.view.choice),
            self.view.pulse,
        });
        for (self.held_confirmation) |pressed| hash.update(&.{@intFromBool(pressed)});
        for ([_]u64{
            self.score,
            self.last_second_tick,
            if (self.clock) |clock| clock.next_tick else 0,
        }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
        hash.update(&.{
            @intFromBool(self.outcome != null),
            if (self.outcome) |choice| @backingInt(choice) else 0,
        });
        const origin = if (self.clock) |clock| clock.origin_ns else 0;
        for (self.events.items) |input| {
            hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, input.time_ns -| origin)));
            hash.update(&std.mem.toBytes(std.mem.nativeToLittle(
                u32,
                @backingInt(std.meta.activeTag(input.payload)),
            )));
            const key: u16 = switch (input.payload) {
                .key_down, .key_up => |press| @backingInt(press.key),
                else => 0,
            };
            hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u16, key)));
        }
        return hash.final();
    }
};
pub const Scene = struct {
    assets: artwork.Assets,
    menu: Menu,
    pub fn init(allocator: std.mem.Allocator, source: platform.AssetSource, score: u32) !Scene {
        return .{
            .assets = try artwork.load(allocator, source),
            .menu = Menu.init(allocator, score),
        };
    }
    pub fn deinit(self: *Scene) void {
        self.menu.deinit();
        self.assets.deinit();
        self.* = undefined;
    }
    pub fn event(self: *Scene, input: platform.Event) !void {
        try self.menu.event(input);
    }
    pub fn update(self: *Scene, now: u64) !void {
        try self.menu.update(now);
    }
    pub fn needsCatchup(self: *const Scene, now: u64) bool {
        return self.menu.needsCatchup(now);
    }
    pub fn stateHash(self: *const Scene) u64 {
        return self.menu.stateHash();
    }
    pub fn draw(self: *const Scene, indices: []u8, rgba: []u8) !void {
        try drawView(&self.assets, self.menu.view, self.menu.score, indices, rgba);
    }
};

pub fn drawView(
    art: *const artwork.Assets,
    view: View,
    score: u32,
    indices: []u8,
    rgba: []u8,
) !void {
    if (indices.len != art.pixels.len) return error.InvalidFrameLength;
    @memcpy(indices, art.pixels);
    const style: text.Style = .{ .foreground = 0xe3, .shadow = 0xe2, .palette_bank = 14 };
    try text.draw(
        indices,
        256,
        224,
        &art.font,
        art.title,
        @divTrunc(256 - @as(i32, @intCast(art.title.len)) * 8, 2),
        64,
        style,
    );
    var buffer: [96]u8 = undefined;
    try text.draw(
        indices,
        256,
        224,
        &art.font,
        try std.fmt.bufPrint(&buffer, "{s}{d}", .{ art.time, view.seconds }),
        96,
        88,
        style,
    );
    for ([_][]const u8{ art.retry, art.abort }, 0..) |label, i| try text.draw(
        indices,
        256,
        224,
        &art.font,
        label,
        @divTrunc(256 - @as(i32, @intCast(label.len)) * 8, 2),
        104 + @as(i32, @intCast(i)) * 8,
        .{
            .foreground = if (i == @backingInt(view.choice)) 0xe4 else 0xe5,
            .shadow = 0xe2,
            .palette_bank = 14,
        },
    );
    try text.draw(
        indices,
        256,
        224,
        &art.font,
        try std.fmt.bufPrint(&buffer, "{s}{d:0>8}", .{ art.score, score }),
        64,
        154,
        style,
    );
    var colors = art.colors;
    colors[0xe4].g = (view.pulse << 2) | (view.pulse >> 4);
    colors[0xe4].b = colors[0xe4].g;
    try palette.writeRgba(indices, &colors, rgba);
}

test "confirmation precedes navigation while highlights follow the next display poll" {
    var menu = Menu.init(std.testing.allocator, 0);
    defer menu.deinit();
    try menu.update(0);
    const at = menu.clock.?.deadline();
    try menu.event(.{ .time_ns = at, .payload = .{ .key_down = .{ .key = .down } } });
    try menu.update(at);
    try std.testing.expectEqual(Choice.abort, menu.choice);
    try std.testing.expectEqual(Choice.retry, menu.view.choice);
    const next = menu.clock.?.deadline();
    try menu.event(.{ .time_ns = next, .payload = .{ .key_down = .{ .key = .up } } });
    try menu.event(.{ .time_ns = next, .payload = .{ .key_down = .{ .key = .enter } } });
    try menu.update(next);
    try std.testing.expectEqual(@as(?Choice, .abort), menu.outcome);
    try std.testing.expectEqual(@as(?platform.Key, .enter), menu.activation_key);
}

test "the Continue clock keeps all eleven countdown values and bounds catch-up work" {
    var menu = Menu.init(std.testing.allocator, 0);
    defer menu.deinit();
    try menu.update(0);
    try std.testing.expectEqual(@as(i16, 10), menu.view.seconds);
    try menu.update(20 * std.time.ns_per_s);
    try std.testing.expect(menu.outcome == null);
    var seen: [11]bool = @splat(false);
    while (menu.outcome == null) {
        try menu.update(menu.clock.?.deadline());
        if (menu.view.seconds >= 0 and
            menu.view.seconds <= 10) seen[@intCast(menu.view.seconds)] = true;
        try std.testing.expect(menu.pulse <= 62 and menu.pulse % 2 == 0);
    }
    for (seen) |value| try std.testing.expect(value);
    try std.testing.expectEqual(@as(?Choice, .abort), menu.outcome);
}

test "released taps vanish before polling and simultaneous directions are consumed in order" {
    var menu = Menu.init(std.testing.allocator, 0);
    defer menu.deinit();
    try menu.event(.{ .time_ns = 0, .payload = .{ .key_down = .{ .key = .enter } } });
    try menu.event(.{ .time_ns = 0, .payload = .{ .key_up = .{ .key = .enter } } });
    try menu.event(.{ .time_ns = 0, .payload = .{ .key_down = .{ .key = .up } } });
    try menu.event(.{ .time_ns = 0, .payload = .{ .key_down = .{ .key = .down } } });
    try menu.update(0);
    try std.testing.expect(menu.outcome == null);
    try std.testing.expectEqual(Choice.retry, menu.choice);
    try menu.update(menu.clock.?.deadline());
    try std.testing.expectEqual(Choice.abort, menu.choice);
}
