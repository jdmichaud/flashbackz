//! The player's settings: one value the game owns and passes to what reads it, kept between runs
//! as one record. A record of another version, or one that does not read, gives the defaults
//! (docs/lessons.md: one save format).
const std = @import("std");
const platform = @import("platform.zig");
const input = @import("input.zig");
const memory = @import("memory.zig");

pub const Difficulty = enum { easy, normal, expert };

pub const Zoom = enum { off, on, auto };

/// A gamepad's named buttons, in SDL's numbering (`platform.ControllerButton`'s named ones).
pub const Button = enum {
    a,
    b,
    x,
    y,
    back,
    guide,
    start,
    left_stick,
    right_stick,
    left_shoulder,
    right_shoulder,
    dpad_up,
    dpad_down,
    dpad_left,
    dpad_right,

    /// A pad's button, if it is one of the named ones.
    pub fn of(button: platform.ControllerButton) ?Button {
        return std.enums.fromInt(Button, @backingInt(button));
    }

    pub fn controller(self: Button) platform.ControllerButton {
        return @fromBackingInt(@backingInt(self));
    }

    pub fn isDirection(self: Button) bool {
        return switch (self) {
            .dpad_up, .dpad_down, .dpad_left, .dpad_right => true,
            else => false,
        };
    }
};

/// The pad buttons a pad model gives the game's actions, by SDL's gamepad names (PLAN GS-3a).
/// The defaults are the fixed layout the rest of the game reads.
pub const PadLayout = struct {
    act: Button = .a,
    gun: Button = .b,
    use: Button = .x,
    inventory: Button = .y,
    pause: Button = .start,

    pub const actions = [_]input.Action{ .act, .gun, .use, .inventory, .pause };

    pub fn place(self: *PadLayout, action: input.Action) ?*Button {
        return switch (action) {
            .act => &self.act,
            .gun => &self.gun,
            .use => &self.use,
            .inventory => &self.inventory,
            .pause => &self.pause,
            else => null,
        };
    }

    /// The fixed layout's button that `button`, pressed on a pad of this layout, stands for: the
    /// button of the action the layout gives it; none for a fixed action button it gives no
    /// action; any other button (the D-pad's) itself.
    pub fn standard(self: PadLayout, button: Button) ?Button {
        var layout = self;
        var fixed: PadLayout = .{};
        for (actions) |action| {
            if (layout.place(action).?.* == button) return fixed.place(action).?.*;
        }
        for (actions) |action| {
            if (fixed.place(action).?.* == button) return null;
        }
        return button;
    }

    /// Gives `action` `button`; the action that had it takes `action`'s old one.
    pub fn bind(self: *PadLayout, action: input.Action, button: Button) void {
        const own = self.place(action) orelse return;
        for (actions) |other| {
            const other_place = self.place(other).?;
            if (other != action and other_place.* == button) {
                other_place.* = own.*;
            }
        }
        own.* = button;
    }
};

/// A pad model's layout, by its GUID.
pub const PadModel = struct {
    guid: [32]u8,
    layout: PadLayout,
};
pub const max_pad_models = 8;

/// The player's settings. Game owns them and gives them to the scenes.
pub const Settings = struct {
    /// The master volume, in percent.
    volume: u8 = 100,
    sound_fx: bool = true,
    music: bool = true,
    /// The original's Joystick option: the pads drive Conrad.
    joystick: bool = false,
    /// The zoom view (flashback-re engine-presentation 4.3). The record keeps it, but only the
    /// automatic zoom lasts beyond a level: a level that starts takes only AUTO from it. A
    /// permanent zoom does not survive a new level, a new game or a continue.
    zoom: Zoom = .off,
    /// The pad models given a layout other than the fixed one.
    pads: [max_pad_models]?PadModel = @splat(null),

    /// The layout of pad model `guid`.
    pub fn padLayout(self: *const Settings, guid: [32]u8) PadLayout {
        for (self.pads) |entry| {
            if (entry) |model| {
                if (std.mem.eql(u8, &model.guid, &guid)) return model.layout;
            }
        }
        return .{};
    }

    /// Keeps `layout` for pad model `guid`; the fixed layout is kept by forgetting the model.
    /// With every place taken, the model given a layout first is forgotten.
    pub fn setPadLayout(self: *Settings, guid: [32]u8, layout: PadLayout) void {
        var kept: [max_pad_models]?PadModel = @splat(null);
        var count: usize = 0;
        for (self.pads) |entry| {
            if (entry) |model| {
                if (std.mem.eql(u8, &model.guid, &guid)) continue;
                kept[count] = model;
                count += 1;
            }
        }
        if (!std.meta.eql(layout, PadLayout{})) {
            if (count == max_pad_models) {
                std.mem.copyForwards(?PadModel, kept[0..max_pad_models - 1], kept[1..]);
                count -= 1;
            }
            kept[count] = .{ .guid = guid, .layout = layout };
        }
        self.pads = kept;
    }
};

pub const record_name = "SETTINGS";

/// The record's format. Any change to it is a new version, and records of the others are
/// refused.
const version = 2;

/// The record as written: its version, then every setting, none left out.
const Record = struct {
    version: u32,
    volume: u8,
    sound_fx: bool,
    music: bool,
    joystick: bool,
    zoom: Zoom,
    pads: []const RecordPad,
};
const RecordPad = struct {
    model: []const u8,
    act: Button,
    gun: Button,
    use: Button,
    inventory: Button,
    pause: Button,
};

/// Room for the largest record: 8 pad models whose layouts use the longest button names take
/// about 2,150 bytes (test "the largest record ...").
const max_record = 4096;

/// The settings kept in `storage`, or the defaults.
pub fn load(storage: ?platform.Storage) Settings {
    const source = storage orelse return .{};
    var record = source.load(record_name) catch return .{};
    defer record.deinit();
    return decode(record.bytes) orelse .{};
}

pub fn save(storage: ?platform.Storage, settings: Settings) platform.StorageError!void {
    const destination = storage orelse return;
    var buffer: [max_record]u8 = undefined;
    try destination.save(record_name, encode(settings, &buffer));
}

fn encode(settings: Settings, buffer: *[max_record]u8) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    var pads: [max_pad_models]RecordPad = undefined;
    var count: usize = 0;
    for (&settings.pads) |*entry| {
        if (entry.*) |*model| {
            const layout = model.layout;
            pads[count] = .{
                .model = &model.guid,
                .act = layout.act,
                .gun = layout.gun,
                .use = layout.use,
                .inventory = layout.inventory,
                .pause = layout.pause,
            };
            count += 1;
        }
    }
    const record: Record = .{
        .version = version,
        .volume = settings.volume,
        .sound_fx = settings.sound_fx,
        .music = settings.music,
        .joystick = settings.joystick,
        .zoom = settings.zoom,
        .pads = pads[0..count],
    };
    std.zon.stringify.serialize(record, .{}, &writer) catch unreachable;
    writer.writeByte('\n') catch unreachable;
    return writer.buffered();
}

fn decode(bytes: []const u8) ?Settings {
    var source: [max_record:0]u8 = undefined;
    if (bytes.len > max_record) return null;
    @memcpy(source[0..bytes.len], bytes);
    source[bytes.len] = 0;
    var scratch: [16384]u8 = undefined;
    var allocator: std.heap.FixedBufferAllocator = .init(&scratch);
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const record = std.zon.parse.fromSlice(Record, .{
        .gpa = allocator.allocator(),
        .arena = allocator.allocator(),
        .source = source[0..bytes.len :0],
        .diagnostics = &diagnostics,
    }) catch return null;
    if (record.version != version or record.volume > 100 or record.pads.len > max_pad_models) {
        return null;
    }
    var settings: Settings = .{
        .volume = record.volume,
        .sound_fx = record.sound_fx,
        .music = record.music,
        .joystick = record.joystick,
        .zoom = record.zoom,
    };
    for (record.pads, 0..) |pad, i| {
        if (pad.model.len != 32) return null;
        // The writer keeps each model once, with five different buttons, none of the D-pad's
        // (`PadLayout.bind`); a record that breaks this was not written by it.
        for (record.pads[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier.model, pad.model)) return null;
        }
        const buttons = [_]Button{ pad.act, pad.gun, pad.use, pad.inventory, pad.pause };
        for (buttons, 0..) |button, b| {
            if (button.isDirection()) return null;
            if (std.mem.indexOfScalar(Button, buttons[0..b], button) != null) return null;
        }
        settings.pads[i] = .{
            .guid = pad.model[0..32].*,
            .layout = .{
                .act = pad.act,
                .gun = pad.gun,
                .use = pad.use,
                .inventory = pad.inventory,
                .pause = pad.pause,
            },
        };
    }
    return settings;
}

test "settings come back as saved, and a record of another version or that does not read gives the defaults" {
    var store = memory.MemoryStorage.init(std.testing.allocator);
    defer store.deinit();
    try std.testing.expectEqual(Settings{}, load(store.storage()));
    try std.testing.expectEqual(Settings{}, load(null));
    var chosen: Settings = .{
        .volume = 40,
        .sound_fx = false,
        .music = false,
        .joystick = true,
        .zoom = .auto,
    };
    var layout: PadLayout = .{};
    layout.bind(.act, .left_shoulder);
    chosen.setPadLayout(@splat('0'), layout);
    try save(store.storage(), chosen);
    try std.testing.expectEqual(chosen, load(store.storage()));

    const refused = [_][]const u8{
        ".{ .version = 1, .volume = 40, .sound_fx = false, .music = false, .joystick = true, .zoom = .auto }",
        ".{ .version = 2, .volume = 140, .sound_fx = false, .music = false, .joystick = true, .zoom = .auto, .pads = .{} }",
        ".{ .version = 2, .volume = 40, .sound_fx = false, .music = false, .zoom = .auto, .pads = .{} }",
        ".{ .version = 2, .volume = 40, .sound_fx = false, .music = false, .joystick = true, .zoom = .auto, .pads = .{}, .extra = 1 }",
        ".{ .version = 2, .volume = 40, .sound_fx = false, .music = false, .joystick = true, .zoom = .auto, .pads = .{ .{ .model = \"short\", .act = .a, .gun = .b, .use = .x, .inventory = .y, .pause = .start } } }",
        // A button twice, a D-pad button, a model twice.
        ".{ .version = 2, .volume = 40, .sound_fx = false, .music = false, .joystick = true, .zoom = .auto, .pads = .{ .{ .model = \"00000000000000000000000000000001\", .act = .a, .gun = .a, .use = .x, .inventory = .y, .pause = .start } } }",
        ".{ .version = 2, .volume = 40, .sound_fx = false, .music = false, .joystick = true, .zoom = .auto, .pads = .{ .{ .model = \"00000000000000000000000000000001\", .act = .dpad_up, .gun = .b, .use = .x, .inventory = .y, .pause = .start } } }",
        ".{ .version = 2, .volume = 40, .sound_fx = false, .music = false, .joystick = true, .zoom = .auto, .pads = .{ .{ .model = \"00000000000000000000000000000001\", .act = .b, .gun = .a, .use = .x, .inventory = .y, .pause = .start }, .{ .model = \"00000000000000000000000000000001\", .act = .y, .gun = .b, .use = .x, .inventory = .a, .pause = .start } } }",
        "50\n",
        "",
    };
    for (refused) |record| {
        try store.storage().save(record_name, record);
        try std.testing.expectEqual(Settings{}, load(store.storage()));
    }
}

test "the largest record fits and reads back" {
    // Every model with the five longest names a layout can hold.
    const layout: PadLayout = .{
        .act = .right_shoulder,
        .gun = .left_shoulder,
        .use = .right_stick,
        .inventory = .left_stick,
        .pause = .guide,
    };
    var largest: Settings = .{ .volume = 100, .zoom = .auto };
    for (0..max_pad_models) |i| {
        var model: [32]u8 = @splat('f');
        model[0] = @intCast('a' + i);
        largest.setPadLayout(model, layout);
    }
    var buffer: [max_record]u8 = undefined;
    const record = encode(largest, &buffer);
    try std.testing.expect(record.len > 2048);
    try std.testing.expectEqual(largest, decode(record).?);
}

test "a pad layout stands its buttons for the fixed layout's, and a bound button swaps places" {
    var layout: PadLayout = .{};
    try std.testing.expectEqual(@as(?Button, .a), layout.standard(.a));
    try std.testing.expectEqual(@as(?Button, .dpad_up), layout.standard(.dpad_up));
    layout.bind(.act, .left_shoulder);
    try std.testing.expectEqual(@as(?Button, .a), layout.standard(.left_shoulder));
    // The fixed action button that no action has any more is no button.
    try std.testing.expectEqual(@as(?Button, null), layout.standard(.a));
    // B given to USE: GUN takes USE's X.
    layout.bind(.use, .b);
    try std.testing.expectEqual(Button.b, layout.use);
    try std.testing.expectEqual(Button.x, layout.gun);
    try std.testing.expectEqual(@as(?Button, .x), layout.standard(.b));
    try std.testing.expectEqual(@as(?Button, .b), layout.standard(.x));
}

test "pad models keep their layouts, the fixed one by forgetting the model" {
    var settings: Settings = .{};
    var layout: PadLayout = .{};
    layout.bind(.gun, .y);
    const guid: [32]u8 = @splat('1');
    settings.setPadLayout(guid, layout);
    try std.testing.expectEqual(layout, settings.padLayout(guid));
    try std.testing.expectEqual(PadLayout{}, settings.padLayout(@splat('2')));
    settings.setPadLayout(guid, .{});
    try std.testing.expectEqual(Settings{}, settings);
    // Full: the first model is forgotten.
    for (0..max_pad_models + 1) |i| {
        var model: [32]u8 = @splat('3');
        model[0] = @intCast('a' + i);
        settings.setPadLayout(model, layout);
    }
    var first: [32]u8 = @splat('3');
    first[0] = 'a';
    try std.testing.expectEqual(PadLayout{}, settings.padLayout(first));
}
