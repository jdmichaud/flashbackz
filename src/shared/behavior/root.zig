//! Character behavior as data: the vocabulary of conditions and effects, the data-set loader
//! and the engine that runs behavior tables (DESIGN.md sections 3 and 4).
pub const vocabulary = @import("vocabulary.zig");
pub const data_set = @import("data_set.zig");
pub const grid = @import("grid.zig");
pub const original_memory = @import("original_memory.zig");
pub const animations = @import("animations.zig");
pub const contacts = @import("contacts.zig");
pub const world = @import("world.zig");
pub const operations = @import("operations.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
