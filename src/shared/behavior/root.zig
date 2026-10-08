//! Character behavior as data: the vocabulary of conditions and effects, the data-set loader
//! and the engine that runs behavior tables (DESIGN.md sections 3 and 4).
pub const vocabulary = @import("vocabulary.zig");
pub const data_set = @import("data_set.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
