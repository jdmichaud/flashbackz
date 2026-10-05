//! Paged world dialogue. Content supplies lines and inks; the modal owns only its page,
//! acknowledgement latch and display clock, while the scene retains the paused world.
const std = @import("std");
const platform = @import("platform.zig");
const clock = @import("step_clock.zig");
pub const Id = enum(u16) { _ };
pub const Line = struct { text: []const u8, ink: u8 };
pub const Page = struct { lines: []const Line };
pub const Message = struct { pages: []const Page };
pub const Request = struct { message: Id, icon: @import("motion.zig").VisualId };
pub const State = struct {
    request: Request,
    page: usize = 0,
    keys: u3 = 0,
    confirm_latched: bool = false,
    clock: clock.Clock,
    pub fn init(request: Request, now: u64) !State {
        var cadence = clock.inventory;
        cadence.initial_gap_ticks = 3;
        cadence.regular_gap_ticks = 3;
        var timer = try clock.Clock.init(cadence, now);
        timer.consume();
        return .{ .request = request, .clock = timer };
    }
    pub fn event(self: *State, input: platform.Event) void {
        const down = input.payload == .key_down;
        const key = switch (input.payload) {
            .key_down, .key_up => |value| value.key,
            .focus_lost => {
                self.keys = 0;
                return;
            },
            else => return,
        };
        const bit: u3 = switch (key) {
            .left_shift, .right_shift => 1,
            .enter => 2,
            .space => 4,
            else => 0,
        };
        if (down) self.keys |= bit else self.keys &= ~bit;
    }
    /// Input is sampled before the three-retrace wait and applied when it completes.
    pub fn poll(self: *State, message: Message) bool {
        if (self.confirm_latched) {
            self.page += 1;
            self.keys = 0;
            self.confirm_latched = false;
            if (self.page >= message.pages.len) return true;
        }
        self.confirm_latched = false;
        self.clock.consume();
        return false;
    }
    pub fn latchInput(self: *State) void {
        self.confirm_latched = self.keys != 0;
    }
    pub fn draw(self: State, message: Message, font: *const @import("content/font.zig").Font, background: []const u8, pixels: []u8) !void {
        if (pixels.len != 256 * 224 or background.len != pixels.len or self.page >= message.pages.len) return error.InvalidMessagePage;
        for (26..58) |row| @memcpy(pixels[row * 256 + 16 ..][0..128], background[row * 256 + 16 ..][0..128]);
        for (message.pages[self.page].lines, 0..) |line, index| {
            const x = 88 - @as(i32, @intCast(line.text.len)) * 4;
            try @import("render/text.zig").draw(pixels, 256, 224, font, line.text, x, 26 + @as(i32, @intCast(index)) * 8, .{ .foreground = line.ink, .shadow = 0xe2, .palette_bank = 14 });
        }
    }
    pub fn hashInto(self: State, hash: *std.hash.Wyhash) void {
        for ([_]u64{ @backingInt(self.request.message), @backingInt(self.request.icon), self.page, self.keys, @intFromBool(self.confirm_latched), self.clock.next_tick }) |value| hash.update(&std.mem.toBytes(std.mem.nativeToLittle(u64, value)));
    }
};
