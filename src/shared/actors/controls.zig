const motion = @import("../motion.zig");

pub const Vertical = enum { up, down };
pub const Intent = struct {
    direction: ?motion.Facing = null,
    vertical: ?Vertical = null,
    action: bool = false,
    use_item: bool = false,
    /// Opposite keys on one axis are held together; no single direction was requested.
    directions_conflict: bool = false,

    pub fn neutralDirections(self: Intent) bool {
        return !self.directions_conflict and self.direction == null and self.vertical == null;
    }
};
