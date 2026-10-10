//! The player's input as the game reads it (flashback-re engine-presentation 6): the fixed
//! layouts that turn keys and gamepad buttons into the game's actions, and the tracker of what
//! is held, which sees every event whatever screen is open.
const std = @import("std");
const platform = @import("platform.zig");

/// The game's actions: the bits of the original's input byte, in order, then pause (Escape),
/// which is outside the byte.
pub const Action = enum {
    up,
    down,
    left,
    right,
    use,
    gun,
    act,
    inventory,
    pause,

    /// The action's bit in the input byte; pause has none.
    pub fn bit(self: Action) u8 {
        return if (self == .pause) 0 else @as(u8, 1) << @intCast(@backingInt(self));
    }

    pub fn isDirection(self: Action) bool {
        return switch (self) {
            .up, .down, .left, .right => true,
            else => false,
        };
    }
};

/// The keyboard's layout, the original's keys (the keypad's arrows arrive as arrows).
pub fn keyAction(key: platform.Key) ?Action {
    return switch (key) {
        .up => .up,
        .down => .down,
        .left => .left,
        .right => .right,
        .enter => .use,
        .space => .gun,
        .left_shift, .right_shift => .act,
        .tab, .backspace => .inventory,
        .escape => .pause,
        else => null,
    };
}

/// The gamepad's layout: the D-pad's directions, the original joystick's four buttons (fire,
/// Space, Return and the inventory) on A, B, X and Y, and START for pause (PLAN GS-3).
pub fn buttonAction(button: platform.ControllerButton) ?Action {
    return switch (button) {
        .dpad_up => .up,
        .dpad_down => .down,
        .dpad_left => .left,
        .dpad_right => .right,
        .a => .act,
        .b => .gun,
        .x => .use,
        .y => .inventory,
        .start => .pause,
        else => null,
    };
}

/// A press or release of an action, from the keyboard (`repeat` when the keyboard repeats a
/// held key) or from a pad.
pub const Change = struct { action: Action, down: bool, repeat: bool = false, pad: bool = false };

/// The changes one event makes: a stick moved from one side to the other releases a direction
/// and presses its opposite.
pub const Changes = struct {
    items: [2]Change = undefined,
    len: usize = 0,

    pub fn slice(self: *const Changes) []const Change {
        return self.items[0..self.len];
    }

    fn add(self: *Changes, change: Change) void {
        self.items[self.len] = change;
        self.len += 1;
    }
};

/// What each pad holds, as input bits: its stick's directions and its buttons, each pad its
/// own, so a pad removed takes only its own away.
pub const Pads = struct {
    const max = 8;
    ids: [max]?platform.ControllerId = @splat(null),
    stick: [max]u8 = @splat(0),
    buttons: [max]u8 = @splat(0),

    /// A stick past a quarter of its travel holds that direction.
    const quarter = 8192;

    pub fn held(self: *const Pads) u8 {
        var bits: u8 = 0;
        for (self.stick, self.buttons) |stick, buttons| bits |= stick | buttons;
        return bits;
    }

    /// A direction the pads hold, as a repeated press: the menus repeat it as the keyboard
    /// repeats a held arrow, which the original's latch then counts (engine-presentation 6.4).
    pub fn repeat(self: *const Pads) ?Change {
        const bits = self.held();
        for ([_]Action{ .up, .down, .left, .right }) |action| {
            if (bits & action.bit() != 0) return .{ .action = action, .down = true, .repeat = true, .pad = true };
        }
        return null;
    }

    /// Applies a pad's event, and returns the changes of the actions it holds.
    pub fn apply(self: *Pads, payload: platform.Event.Payload) Changes {
        var changes: Changes = .{};
        switch (payload) {
            .controller_axis => |motion| {
                const negative: Action, const positive: Action = switch (motion.axis) {
                    .left_x => .{ .left, .right },
                    .left_y => .{ .up, .down },
                    else => return changes,
                };
                const at = self.slot(motion.controller) orelse return changes;
                const before = self.stick[at];
                const axis = negative.bit() | positive.bit();
                var now = before & ~axis;
                if (motion.value < -quarter) now |= negative.bit();
                if (motion.value > quarter) now |= positive.bit();
                self.stick[at] = now;
                for ([_]Action{ negative, positive }) |action| {
                    const was = before & action.bit() != 0;
                    const is = now & action.bit() != 0;
                    if (was != is) changes.add(.{ .action = action, .down = is, .pad = true });
                }
            },
            .controller_button_down, .controller_button_up => |change| {
                const action = buttonAction(change.button) orelse return changes;
                const at = self.slot(change.controller) orelse return changes;
                const down = payload == .controller_button_down;
                if (down) self.buttons[at] |= action.bit() else self.buttons[at] &= ~action.bit();
                changes.add(.{ .action = action, .down = down, .pad = true });
            },
            .controller_removed => |id| for (&self.ids, &self.stick, &self.buttons) |*slot_id, *stick, *buttons| {
                if (slot_id.* != id) continue;
                slot_id.* = null;
                stick.* = 0;
                buttons.* = 0;
            },
            else => {},
        }
        return changes;
    }

    /// The slot of pad `id`, taking a free one for a pad not seen yet; null when all are taken.
    fn slot(self: *Pads, id: platform.ControllerId) ?usize {
        for (self.ids, 0..) |slot_id, i| if (slot_id == id) return i;
        for (&self.ids, 0..) |*slot_id, i| if (slot_id.* == null) {
            slot_id.* = id;
            return i;
        };
        return null;
    }
};

/// The keyboard as the original reads it: one byte of held keys (no edge detection) and the
/// last direction held without a diagonal. After a modal screen the held keys are released:
/// a key still down counts again only when pressed anew (or when the keyboard repeats it).
/// It sees every event, whatever screen is open, so a key released during a modal screen is
/// armed again, as in the original's latch (engine-presentation 6.4).
pub const Tracker = struct {
    held: u8 = 0,
    /// Keys physically down, and those of them released by a modal screen.
    down: u8 = 0,
    ignored: u8 = 0,
    last_direction: u8 = 0,
    /// Escape held, in play: a level, as the original's (engine-presentation 6.1). Modal
    /// screens take Escape themselves and leave it.
    escape: bool = false,
    /// What the joystick or gamepads hold. The original polls the joystick before every update
    /// when the Joystick option is on, pressing again whatever is held, so these bits are not
    /// released by modal screens (engine-presentation 6.2).
    pads: Pads = .{},

    /// The held byte an update reads: the keyboard's, and the pads' when the joystick is on.
    pub fn read(self: *const Tracker, joystick: bool) u8 {
        return self.held | if (joystick) self.pads.held() else 0;
    }

    /// Applies one event to what is held, and returns the changes it makes for the screens.
    pub fn apply(self: *Tracker, payload: platform.Event.Payload) Changes {
        var changes: Changes = .{};
        switch (payload) {
            .focus_lost => self.lose(),
            .key_down, .key_up => |key| {
                const action = keyAction(key.key) orelse return changes;
                const down = payload == .key_down;
                self.press(action, down, key.repeat);
                changes.add(.{ .action = action, .down = down, .repeat = key.repeat });
            },
            else => return self.pads.apply(payload),
        }
        return changes;
    }

    pub fn release(self: *Tracker) void {
        self.ignored |= self.down;
        self.held = 0;
    }

    pub fn lose(self: *Tracker) void {
        self.* = .{ .last_direction = self.last_direction, .pads = self.pads };
    }

    fn press(self: *Tracker, action: Action, down: bool, repeat: bool) void {
        const bit = action.bit();
        if (bit == 0) return;
        if (down) {
            self.down |= bit;
            if (repeat) self.ignored &= ~bit;
            if (self.ignored & bit == 0) self.held |= bit;
        } else {
            self.down &= ~bit;
            self.ignored &= ~bit;
            self.held &= ~bit;
        }
    }

    /// Holding a vertical and a horizontal direction keeps the last single direction, with the
    /// buttons held now.
    pub fn collapse(self: *Tracker, raw: u8) u8 {
        if (raw & 0x03 != 0 and raw & 0x0c != 0) return (raw & 0xf0) | (self.last_direction & 0x0f);
        self.last_direction = raw;
        return raw;
    }
};

fn pad(id: u32) platform.ControllerId {
    return @fromBackingInt(id);
}

test "the layouts give the input byte's bits" {
    try std.testing.expectEqual(@as(u8, 0x40), keyAction(.right_shift).?.bit());
    try std.testing.expectEqual(@as(u8, 0x80), keyAction(.backspace).?.bit());
    try std.testing.expectEqual(@as(u8, 0), keyAction(.escape).?.bit());
    try std.testing.expectEqual(@as(?Action, null), keyAction(.p));
    try std.testing.expectEqual(Action.use, buttonAction(.x).?);
}

test "the joystick holds directions and buttons beside the keyboard when enabled" {
    var keys: Tracker = .{};
    _ = keys.apply(.{ .controller_axis = .{ .controller = pad(0), .axis = .left_x, .value = 20000 } });
    _ = keys.apply(.{ .controller_button_down = .{ .controller = pad(0), .button = .a } });
    try std.testing.expectEqual(@as(u8, 0), keys.read(false));
    try std.testing.expectEqual(@as(u8, 0x48), keys.read(true));
    // A small deflection is the centre; the keyboard adds its own bits.
    _ = keys.apply(.{ .controller_axis = .{ .controller = pad(0), .axis = .left_x, .value = 4000 } });
    _ = keys.apply(.{ .key_down = .{ .key = .space } });
    try std.testing.expectEqual(@as(u8, 0x60), keys.read(true));
    // A modal screen releases the keyboard's keys but not what the joystick holds.
    keys.release();
    try std.testing.expectEqual(@as(u8, 0x40), keys.read(true));
    _ = keys.apply(.{ .controller_button_up = .{ .controller = pad(0), .button = .a } });
    _ = keys.apply(.{ .controller_button_down = .{ .controller = pad(0), .button = .dpad_up } });
    try std.testing.expectEqual(@as(u8, 0x01), keys.read(true));
    _ = keys.apply(.{ .controller_removed = pad(0) });
    try std.testing.expectEqual(@as(u8, 0), keys.read(true));
}

test "each pad holds its own buttons" {
    var keys: Tracker = .{};
    _ = keys.apply(.{ .controller_button_down = .{ .controller = pad(1), .button = .b } });
    _ = keys.apply(.{ .controller_button_down = .{ .controller = pad(2), .button = .b } });
    _ = keys.apply(.{ .controller_button_up = .{ .controller = pad(1), .button = .b } });
    try std.testing.expectEqual(@as(u8, 0x20), keys.read(true));
    _ = keys.apply(.{ .controller_removed = pad(1) });
    try std.testing.expectEqual(@as(u8, 0x20), keys.read(true));
    _ = keys.apply(.{ .controller_removed = pad(2) });
    try std.testing.expectEqual(@as(u8, 0), keys.read(true));
}

test "a stick across releases one direction and presses the other" {
    var keys: Tracker = .{};
    _ = keys.apply(.{ .controller_axis = .{ .controller = pad(0), .axis = .left_x, .value = -30000 } });
    const changes = keys.apply(.{ .controller_axis = .{ .controller = pad(0), .axis = .left_x, .value = 30000 } });
    try std.testing.expectEqualSlices(Change, &.{
        .{ .action = .left, .down = false, .pad = true },
        .{ .action = .right, .down = true, .pad = true },
    }, changes.slice());
}

test "a key held through a modal screen counts again only once pressed anew" {
    var keys: Tracker = .{};
    _ = keys.apply(.{ .key_down = .{ .key = .enter } });
    try std.testing.expectEqual(@as(u8, 0x10), keys.held);
    keys.release();
    try std.testing.expectEqual(@as(u8, 0), keys.held);
    _ = keys.apply(.{ .key_down = .{ .key = .enter } });
    try std.testing.expectEqual(@as(u8, 0), keys.held);
    _ = keys.apply(.{ .key_down = .{ .key = .enter, .repeat = true } });
    try std.testing.expectEqual(@as(u8, 0x10), keys.held);
    keys.release();
    _ = keys.apply(.{ .key_up = .{ .key = .enter } });
    _ = keys.apply(.{ .key_down = .{ .key = .enter } });
    try std.testing.expectEqual(@as(u8, 0x10), keys.held);
}

test "diagonals keep the last single direction with the current buttons" {
    var keys: Tracker = .{};
    try std.testing.expectEqual(@as(u8, 0x08), keys.collapse(0x08));
    try std.testing.expectEqual(@as(u8, 0x48), keys.collapse(0x49));
    try std.testing.expectEqual(@as(u8, 0x03), keys.collapse(0x03));
    try std.testing.expectEqual(@as(u8, 0x23), keys.collapse(0x25));
}
