//! An environmental call sequence: quiet intervals, ordered chances and optional repeats.
const geometry = @import("geometry.zig");
pub const SoundId = @import("motion.zig").SoundId;
pub const Call = struct { sound: SoundId, duration: u16, chance: u16, repeat_chance: ?u16 = null };
pub const Definition = struct { quiet_steps: u16, calls: []const Call };
pub const Event = struct { sound: SoundId, room: geometry.RoomId };
pub const State = struct {
    call: ?usize = null,
    elapsed: u16 = 0,
    room: ?geometry.RoomId = null,
    fn succeeds(random: anytype, denominator: u16) bool {
        return @rem(@as(i16, @bitCast(random.next())), @as(i16, @intCast(denominator))) == 0;
    }
    pub fn advance(self: *State, definition: Definition, room: geometry.RoomId, random: anytype) ?Event {
        const duration = if (self.call) |index| definition.calls[index].duration else definition.quiet_steps;
        var event: ?Event = null;
        if (self.elapsed == duration) {
            self.elapsed = 0;
            if (self.call) |index| {
                const current = definition.calls[index];
                if (current.repeat_chance != null and succeeds(random, current.repeat_chance.?)) {
                    event = .{ .sound = current.sound, .room = self.room.? };
                } else self.call = null;
            } else for (definition.calls, 0..) |candidate, index| {
                if (succeeds(random, candidate.chance)) {
                    self.call = index;
                    self.room = room;
                    event = .{ .sound = candidate.sound, .room = room };
                    break;
                }
            }
        }
        self.elapsed += 1;
        return event;
    }
};
