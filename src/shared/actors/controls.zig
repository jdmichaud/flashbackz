const motion = @import("../motion.zig");

pub const Vertical = enum { up, down };
pub const Intent = struct {
    direction: ?motion.Facing = null,
    vertical: ?Vertical = null,
    action: bool = false,
};
