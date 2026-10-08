//! Immutable character work order. Tasks select independent behavior components, not
//! source instructions; each produces events before the next character is advanced.
pub const Task = union(enum) {
    gunman: usize,
    guard: usize,
    quest_contact: usize,
    rescue_contact: usize,
    host: usize,
    service_counter: usize,
    player_shot,
};
