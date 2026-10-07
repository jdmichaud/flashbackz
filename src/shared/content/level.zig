//! Content families share room art while carrying their own actor and puzzle definitions.
pub const Id = enum { jungle, city, tower, earth_city, spaceport, alien_surface, alien_base };
pub const Files = struct { actors: []const u8, rooms: []const u8, tile_bias: u16 = 0 };
pub fn files(id: Id) Files {
    return switch (id) {
        .jungle => .{ .actors = "LEVEL1", .rooms = "LEVEL1", .tile_bias = 896 },
        .city => .{ .actors = "LEVEL2", .rooms = "LEVEL2" },
        .tower => .{ .actors = "LEVEL3", .rooms = "LEVEL3" },
        .earth_city => .{ .actors = "LEVEL4_1", .rooms = "LEVEL4" },
        .spaceport => .{ .actors = "LEVEL4_2", .rooms = "LEVEL4" },
        .alien_surface => .{ .actors = "LEVEL5_1", .rooms = "LEVEL5" },
        .alien_base => .{ .actors = "LEVEL5_2", .rooms = "LEVEL5" },
    };
}

/// Opening films recovered from the edition's level descriptors. The jungle opening
/// is owned by the title scene; levels without an entry film begin directly in play.
pub fn opening(id: Id) ?@import("../story_cue.zig").Cue {
    return switch (id) {
        .city => .city_arrival,
        .earth_city => .earth_arrival,
        .spaceport => .spaceport_arrival,
        .alien_surface => .alien_arrival,
        .jungle, .tower, .alien_base => null,
    };
}
