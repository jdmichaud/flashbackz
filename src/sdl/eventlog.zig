//! The event log of the SDL host: one JSON object on one line for each delivered platform event.
//!
//! The field names are the names of the platform's types, so an agent host that parses the same
//! lines replays an interactive session headlessly. An enum value that has no name is written as
//! its number; a parser should reject such a line rather than read the number as another value.
const std = @import("std");
const flashbackz = @import("flashbackz");
const platform = flashbackz.platform;

/// Writes `ev` as one JSON object followed by a newline. Does not flush.
pub fn writeEvent(ev: platform.Event, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var js: std.json.Stringify = .{ .writer = w };
    try js.beginObject();
    try js.objectField("kind");
    try js.write(@tagName(std.meta.activeTag(ev.payload)));
    try js.objectField("t");
    try js.write(ev.time_ns);
    switch (ev.payload) {
        .key_down, .key_up => |k| {
            try js.objectField("key");
            try writeEnum(&js, platform.Key, k.key);
            try js.objectField("repeat");
            try js.write(k.repeat);
        },
        .controller_added, .controller_removed => |id| {
            try js.objectField("controller");
            try js.write(@backingInt(id));
        },
        .controller_button_down, .controller_button_up => |b| {
            try js.objectField("controller");
            try js.write(@backingInt(b.controller));
            try js.objectField("button");
            try writeEnum(&js, platform.ControllerButton, b.button);
        },
        .controller_axis => |a| {
            try js.objectField("controller");
            try js.write(@backingInt(a.controller));
            try js.objectField("axis");
            try writeEnum(&js, platform.ControllerAxis, a.axis);
            try js.objectField("value");
            try js.write(a.value);
        },
        .drawable_resized => |size| {
            try js.objectField("width");
            try js.write(size.width);
            try js.objectField("height");
            try js.write(size.height);
        },
        .focus_gained, .focus_lost, .quit => {},
    }
    try js.endObject();
    try w.writeByte('\n');
}

/// The value's name, or its number when the non-exhaustive enum does not name it.
fn writeEnum(js: *std.json.Stringify, comptime E: type, value: E) std.Io.Writer.Error!void {
    if (std.enums.tagName(E, value)) |name| {
        try js.write(name);
    } else {
        try js.write(@backingInt(value));
    }
}

test "events are logged in the agent host's own vocabulary" {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeEvent(
        .{ .time_ns = 12, .payload = .{ .key_down = .{ .key = .s, .repeat = true } } },
        &w,
    );
    try writeEvent(
        .{ .time_ns = 17, .payload = .{ .drawable_resized = .{ .width = 640, .height = 400 } } },
        &w,
    );
    try writeEvent(.{ .time_ns = 18, .payload = .quit }, &w);
    try writeEvent(
        .{
            .time_ns = 20,
            .payload = .{ .controller_axis = .{
                .controller = @fromBackingInt(3),
                .axis = .left_x,
                .value = -300,
            } },
        },
        &w,
    );
    try writeEvent(
        .{ .time_ns = 21, .payload = .{ .key_up = .{ .key = @fromBackingInt(9999) } } },
        &w,
    );

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, w.buffered(), "\n"), '\n');
    try std.testing.expectEqualStrings(
        "{\"kind\":\"key_down\",\"t\":12,\"key\":\"s\",\"repeat\":true}",
        lines.next().?,
    );
    try std.testing.expectEqualStrings(
        "{\"kind\":\"drawable_resized\",\"t\":17,\"width\":640,\"height\":400}",
        lines.next().?,
    );
    try std.testing.expectEqualStrings("{\"kind\":\"quit\",\"t\":18}", lines.next().?);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"controller_axis\",\"t\":20,\"controller\":3,\"axis\":\"left_x\",\"value\":-300}",
        lines.next().?,
    );
    try std.testing.expectEqualStrings(
        "{\"kind\":\"key_up\",\"t\":21,\"key\":9999,\"repeat\":false}",
        lines.next().?,
    );
    try std.testing.expectEqual(@as(?[]const u8, null), lines.next());
}
