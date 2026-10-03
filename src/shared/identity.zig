//! Stable references belong to a session. Generations distinguish a reused slot from
//! the object that previously occupied it; source content identifiers are unrelated.
pub const ItemHandle = struct {
    index: u16,
    generation: u32,

    pub fn eql(a: ItemHandle, b: ItemHandle) bool {
        return a.index == b.index and a.generation == b.generation;
    }
};
