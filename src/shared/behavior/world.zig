//! A level's characters running their behavior tables (DESIGN.md section 4). Each update
//! registers who touches whom, then walks the active characters in placement order. A
//! character either plays the next frame of its animation or, when the animation is done,
//! tries its state's rules in order. The order of every step follows the original
//! (flashback-re `docs/rules/engine-update.md`).
const std = @import("std");
const vocabulary = @import("vocabulary.zig");
const data_set = @import("data_set.zig");
const grid = @import("grid.zig");
const animations = @import("animations.zig");
const contacts = @import("contacts.zig");
const random = @import("../random.zig");
const operations = @import("operations.zig");

/// Conrad's controls as the rules see them, after the original's diagonal handling.
pub const Controls = packed struct(u8) {
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
    enter: bool = false,
    space: bool = false,
    shift: bool = false,
    inventory: bool = false,
};

/// Room values outside the 64 rooms of a level.
pub const Room = struct {
    pub const outside: u8 = 64;
    pub const removed: u8 = 0xfe;
    pub const carried: u8 = 0xff;
};

pub const Character = struct {
    /// Index into the behavior's states.
    state: u16,
    /// Frames of the current animation already played.
    cursor: u8 = 0,
    x: i16,
    y: i16,
    room: u8,
    health: i16,
    counter: i16 = 0,
    facing_right: bool,
    active: bool = false,
    /// Placed in this level's difficulty; others never join a room.
    present: bool,
    /// The first contact slot from the character's last registration.
    contact: u8 = contacts.no_slot,
    /// Inventory: an owner's first item is its selected one; items link to the next.
    owner: ?u16 = null,
    first_item: ?u16 = null,
    next_item: ?u16 = null,
    /// The next character in the same room's list.
    next_in_room: ?u16 = null,
};

pub const Letter = struct { sender: u16, message: vocabulary.Message, next: ?u16 };
/// The original's message pool; sends beyond it are dropped silently.
pub const letter_capacity = 256;

/// A sound a character starts; `distant` when it plays from a room beside the view.
pub const Sound = struct { id: u8, character: u16, distant: bool };

/// What the rest of the game acts on after an update.
pub const Requests = struct {
    scene: ?i16 = null,
    world_message: ?i16 = null,
    level: ?u8 = null,
    sounds: [16]Sound = undefined,
    sound_count: u8 = 0,

    pub fn addSound(self: *Requests, sound: Sound) void {
        if (self.sound_count == self.sounds.len) return;
        self.sounds[self.sound_count] = sound;
        self.sound_count += 1;
    }
};

pub const Outcome = enum {
    /// The update ran; act on `requests`.
    played,
    /// The defeat countdown ran out: show the defeat scene and the continue screen.
    defeated,
    /// A rule asked for another level; load it.
    level_changed,
};

pub const World = struct {
    allocator: std.mem.Allocator,
    level: *const data_set.Level,
    animations: animations.Animations,
    grid: grid.Grid,
    characters: []Character,
    /// The first character of each room's list, for every room byte.
    room_lists: [256]?u16 = @splat(null),
    contacts: contacts.Contacts = .{},
    letters: [letter_capacity]Letter = undefined,
    free_letter: ?u16 = null,
    inbox: []?u16,
    random: random.Stream = .{},
    controls: Controls = .{},
    /// The room on screen, which follows Conrad.
    view_room: u8,
    /// Set when the view must move to Conrad's room after the update.
    view_dirty: bool = true,
    score: u32 = 0,
    /// Updates left in Conrad's protection after a hit.
    protection: u8 = 0,
    /// Conrad was hurt and protection starts when he next listens for hits.
    hurt: bool = false,
    defeat_countdown: i16 = 0,
    defeat_scene: i16 = -1,
    weapon_mode: i16 = 0,
    /// The view's vertical shake offset, -1 to 2.
    shake: i8 = 0,
    requests: Requests = .{},
    /// The updating character's column, tier and facing at the start of its update.
    column: i16 = 0,
    band: i16 = 0,
    updating_facing_right: bool = false,
    /// Cleared during a character's update when its new animation must start silently.
    entry_sound: bool = true,
    /// Probes that read original memory outside the grid that the engine does not model.
    unmodeled_reads: u32 = 0,
    /// The vocabulary name that stopped the engine, when one is not implemented yet.
    missing_operation: ?[]const u8 = null,
    scratch: std.ArrayList(u16) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        level: *const data_set.Level,
        level_animations: animations.Animations,
        collision: grid.Grid,
        difficulty: data_set.Difficulty,
    ) !World {
        const characters = try allocator.alloc(Character, level.characters.len);
        errdefer allocator.free(characters);
        const inbox = try allocator.alloc(?u16, level.characters.len);
        errdefer allocator.free(inbox);
        @memset(inbox, null);
        var world: World = .{
            .allocator = allocator,
            .level = level,
            .animations = level_animations,
            .grid = collision,
            .characters = characters,
            .inbox = inbox,
            .view_room = level.characters[0].room orelse Room.outside,
        };
        for (characters, level.characters, 0..) |*character, definition, index| {
            const present = @backingInt(definition.minimum_difficulty) <= @backingInt(difficulty);
            const doubled = definition.kind == .enemy and @backingInt(difficulty) >= 2;
            const room = definition.room orelse Room.outside;
            character.* = .{
                .state = definition.start,
                .x = definition.x,
                .y = definition.y,
                .room = room,
                .health = if (doubled) definition.health *% 2 else definition.health,
                // Characters left out at this difficulty keep their flags from before; a new
                // game starts them cleared.
                .facing_right = present and definition.facing == .right,
                .present = present,
                .active = present and (definition.active or
                    (definition.wakes_when_near and room == world.view_room)),
            };
            // Lists start in descending placement order: each placement goes to the front.
            if (present) world.pushToRoom(@intCast(index), room);
        }
        world.resetLetters();
        return world;
    }

    pub fn deinit(self: *World) void {
        self.scratch.deinit(self.allocator);
        self.allocator.free(self.characters);
        self.allocator.free(self.inbox);
    }

    // The update ---------------------------------------------------------------------------

    /// One update: the defeat countdown, contacts, then every active character in order.
    /// A catch-up update repeats the walk without advancing countdowns.
    pub fn update(self: *World, controls: Controls, catch_up: bool) !Outcome {
        self.controls = controls;
        self.requests = .{};
        if (!catch_up and self.defeat_countdown & 0xff != 0) {
            self.defeat_countdown -%= 1;
            if (self.defeat_countdown == 0) {
                self.requests.scene = self.defeat_scene;
                return .defeated;
            }
        }
        try self.buildContacts();
        self.contacts.buildWindow(&self.grid, self.view_room);
        for (0..self.characters.len) |i| {
            const index: u16 = @intCast(i);
            // Read when reached: characters woken during the walk run in it if they come later.
            if (!self.characters[index].active) continue;
            try self.updateCharacter(index);
        }
        if (self.requests.level != null) return .level_changed;
        if (self.view_dirty) {
            if (self.view_room == 0xff) {
                self.requests.scene = 6;
                self.defeat_countdown = 1;
            } else self.view_room = self.characters[0].room;
            self.view_dirty = false;
        }
        if (!catch_up and self.protection != 0) self.protection -= 1;
        return .played;
    }

    /// Every character in the view room's list registers its cells (and may wake there), then
    /// every other active character registers. Sharing a cell wakes those that wake on contact.
    fn buildContacts(self: *World) !void {
        self.contacts.begin();
        if (self.view_room < 0x80) {
            var cursor = self.room_lists[self.view_room];
            while (cursor) |index| : (cursor = self.characters[index].next_in_room) {
                try self.register(index);
                const definition = self.level.characters[index];
                const asleep = !self.characters[index].active;
                if (asleep and definition.wakes_when_near) self.activate(index);
            }
        }
        for (self.characters, 0..) |character, i| {
            if (!character.active or character.room == self.view_room) continue;
            try self.register(@intCast(i));
        }
    }

    fn register(self: *World, index: u16) !void {
        const character = &self.characters[index];
        self.scratch.clearRetainingCapacity();
        const first = try self.contacts.register(
            &self.grid,
            index,
            character.room,
            character.x,
            character.y,
            self.level.characters[index].width,
            &self.scratch,
            self.allocator,
        );
        if (first) |slot| character.contact = slot;
        for (self.scratch.items) |shared| {
            if (self.level.characters[shared].wakes_on_contact) self.activate(shared);
        }
    }

    pub fn activate(self: *World, index: u16) void {
        self.characters[index].active = true;
    }

    /// Stops updating the character until something wakes it.
    pub fn deactivate(self: *World, index: u16) void {
        self.characters[index].active = false;
    }

    fn updateCharacter(self: *World, index: u16) !void {
        const character = &self.characters[index];
        self.entry_sound = true;
        self.updating_facing_right = character.facing_right;
        self.column = grid.columnOf(character.x);
        self.band = grid.bandOf(character.y);
        const start_room = character.room;
        if (self.inbox[index] != null) try self.skipToAwaitedRule(index);
        const animation = try self.animationOf(index);
        if (signedByte(animation.count()) > signedByte(character.cursor)) {
            self.playFrame(index, animation);
        } else if (try self.fireFirstRule(index)) {
            const entered = try self.animationOf(index);
            if (entered.sound) |sound| if (self.entry_sound) self.requestSound(index, sound);
            self.afterRule(index, start_room);
            self.playFrame(index, entered);
        }
        self.clearInbox(index);
    }

    /// A message the current state has a rule waiting for ends the animation now: its
    /// remaining movement applies and the rules run in this update.
    fn skipToAwaitedRule(self: *World, index: u16) !void {
        for (self.stateOf(index).rules) |rule| {
            var letters = self.mailbox(index);
            while (letters.nextLetter()) |letter| {
                if (!awaits(rule, letter.message)) continue;
                const character = &self.characters[index];
                const animation = try self.animationOf(index);
                var k: usize = character.cursor;
                while (k < animation.count()) : (k += 1) {
                    const frame = animation.frame(k);
                    if (frame.sprite == null) continue;
                    character.x +%= if (character.facing_right) -frame.dx else frame.dx;
                    character.y +%= frame.dy;
                }
                character.cursor = @intCast(animation.count());
                self.column = grid.columnOf(character.x);
                // This path sign-extends the tier, unlike the walk.
                const quotient: i8 = @truncate(@divTrunc(character.y, 36));
                self.band = @as(i16, quotient) & ~@as(i16, 1);
                return;
            }
        }
    }

    fn awaits(rule: vocabulary.Rule, message: vocabulary.Message) bool {
        for (rule.when) |check| switch (check) {
            .received, .acknowledge => |expected| if (expected == message) return true,
            .hit => |side| switch (side) {
                .from_behind => switch (message) {
                    .hit_behind_high, .hit_behind_low => return true,
                    else => {},
                },
                .from_front => switch (message) {
                    .hit_front_high, .hit_front_low => return true,
                    else => {},
                },
                .from_front_unannounced => {},
            },
            else => {},
        };
        return false;
    }

    /// Advance one frame: the frame's movement points toward the character's back.
    fn playFrame(self: *World, index: u16, animation: animations.Animation) void {
        const character = &self.characters[index];
        if (signedByte(animation.count()) < signedByte(character.cursor)) character.cursor = 0;
        const frame = animation.frame(character.cursor);
        character.cursor +%= 1;
        if (frame.sprite == null) return;
        character.x +%= if (character.facing_right) -frame.dx else frame.dx;
        character.y +%= frame.dy;
    }

    fn signedByte(value: usize) i8 {
        return @bitCast(@as(u8, @truncate(value)));
    }

    // Rules ------------------------------------------------------------------------------

    /// Try the current state's rules in order and apply the first whose checks all hold.
    fn fireFirstRule(self: *World, index: u16) !bool {
        const state = self.stateOf(index);
        for (state.rules) |rule| {
            if (!try self.checksHold(index, rule.when)) continue;
            if (rule.then) |effect| _ = try operations.perform(self, index, effect);
            self.enter(index, rule);
            return true;
        }
        return false;
    }

    fn checksHold(self: *World, index: u16, checks: []const vocabulary.Operation) !bool {
        for (checks) |check| if (!try operations.perform(self, index, check)) return false;
        return true;
    }

    /// Apply a fired rule in the original's order: state, score, turn, health, movement
    /// (toward the facing after any turn), then Conrad's protection.
    fn enter(self: *World, index: u16, rule: vocabulary.Rule) void {
        const character = &self.characters[index];
        const kind = self.level.characters[index].kind;
        character.state = rule.next;
        character.cursor = 0;
        self.score +%= rule.score;
        if (rule.turn) character.facing_right = !character.facing_right;
        if (rule.damage) {
            character.health -%= 1;
            if (kind == .player) self.hurt = true;
            if (kind == .enemy) self.score +%= 100;
        }
        if (rule.heal) character.health +%= 1;
        if (rule.kill) character.health = -1;
        character.x +%= if (character.facing_right) rule.forward else -%rule.forward;
        character.y +%= rule.down;
        // Protection starts once Conrad is in a state that listens for hits again.
        if (self.hurt and kind == .player and listensForHits(self.stateOf(index))) {
            self.protection = 60;
            self.hurt = false;
        }
    }

    fn listensForHits(state: vocabulary.State) bool {
        for (state.rules) |rule| for (rule.when) |check| switch (check) {
            .hit => return true,
            .received => |message| if (message.isHit()) return true,
            else => {},
        };
        return false;
    }

    /// After a rule fires: cross into a neighbor room (one axis, left from x = -10), move the
    /// view with Conrad, and move the character to its new room's list.
    fn afterRule(self: *World, index: u16, start_room: u8) void {
        const character = &self.characters[index];
        const side: ?grid.Side = if (character.x <= -10) blk: {
            character.x +%= 256;
            break :blk .left;
        } else if (character.x >= 256) blk: {
            character.x -%= 256;
            break :blk .right;
        } else if (character.y < 0) blk: {
            character.y +%= 216;
            break :blk .up;
        } else if (character.y >= 216) blk: {
            character.y -%= 216;
            break :blk .down;
        } else null;
        if (side) |s| {
            // A missing neighbor stores 0xff, as in the original.
            if (character.room < 0x80) character.room = self.grid.rawLink(character.room, s);
            if (self.level.characters[index].kind == .player) self.followConrad(character.room);
        }
        if (character.room != start_room) self.moveBetweenRooms(index, start_room, character.room);
    }

    /// Conrad's new room becomes the view at once; characters there wake, and so do some in
    /// the rooms above and below (the original's height filters are kept as coded).
    fn followConrad(self: *World, room: u8) void {
        self.view_room = room;
        self.contacts.buildWindow(&self.grid, room);
        self.view_dirty = true;
        if (room >= 64) return;
        self.wakeRoom(room, null);
        const up = self.grid.rawLink(room, .up);
        if (up < 64) self.wakeRoom(up, 48);
        const down = self.grid.rawLink(room, .down);
        if (down < 64) self.wakeRoom(down, 176);
    }

    fn wakeRoom(self: *World, room: u8, minimum_y: ?i16) void {
        var cursor = self.room_lists[room];
        while (cursor) |index| : (cursor = self.characters[index].next_in_room) {
            const definition = self.level.characters[index];
            if (!definition.wakes_when_near) continue;
            if (minimum_y) |y| {
                if (definition.kind == .enemy or self.characters[index].y < y) continue;
            }
            self.activate(index);
        }
    }

    fn pushToRoom(self: *World, index: u16, room: u8) void {
        self.characters[index].next_in_room = self.room_lists[room];
        self.room_lists[room] = index;
    }

    /// Moves the character only if it is in the old room's list, as the original does.
    fn moveBetweenRooms(self: *World, index: u16, from: u8, to: u8) void {
        var cursor = &self.room_lists[from];
        while (cursor.*) |current| : (cursor = &self.characters[current].next_in_room) {
            if (current != index) continue;
            cursor.* = self.characters[index].next_in_room;
            self.pushToRoom(index, to);
            return;
        }
    }

    // Lookups used by operations --------------------------------------------------------

    pub fn behaviorOf(self: *const World, index: u16) vocabulary.Behavior {
        return self.level.behaviors[self.level.characters[index].behavior];
    }

    pub fn stateOf(self: *const World, index: u16) vocabulary.State {
        return self.behaviorOf(index).states[self.characters[index].state];
    }

    pub fn animationOf(self: *const World, index: u16) !animations.Animation {
        return self.animations.get(self.stateOf(index).animation);
    }

    /// The value of one of the character's numbers.
    pub fn number(self: *const World, index: u16, which: vocabulary.Number) i16 {
        return self.level.characters[index].numbers[@backingInt(which)];
    }

    /// The character a link names, if any.
    pub fn link(self: *const World, index: u16, which: vocabulary.Link) ?u16 {
        const target = self.level.characters[index].links[@backingInt(which)] orelse return null;
        return @backingInt(target);
    }

    /// Takes `item` out of `owner`'s inventory if it is there.
    pub fn unlinkItem(self: *World, owner: u16, item: u16) void {
        var cursor = &self.characters[owner].first_item;
        while (cursor.*) |current| : (cursor = &self.characters[current].next_item) {
            if (current != item) continue;
            cursor.* = self.characters[item].next_item;
            self.characters[item].owner = null;
            self.characters[item].next_item = null;
            return;
        }
    }

    /// Sounds play for awake characters in the view room, or quieter from a room beside it.
    /// Only ids below 66 exist.
    pub fn requestSound(self: *World, index: u16, id: i16) void {
        if (id < 0 or id >= 66) return;
        const character = self.characters[index];
        if (!character.active) return;
        const distant = character.room != self.view_room;
        if (distant) {
            const beside = for (std.enums.values(grid.Side)) |side| {
                if (self.grid.rawLink(self.view_room, side) == character.room) break true;
            } else false;
            if (!beside) return;
        }
        self.requests.addSound(.{ .id = @intCast(id), .character = index, .distant = distant });
    }

    /// A byte the original reads past the grid: the updating character's facing, column and
    /// tier sit there. Other addresses are counted, so a run that depends on them is visible.
    pub fn outsideByte(self: *World, address: u16) i8 {
        const facing: u16 = if (self.updating_facing_right) 0xffff else 0;
        const word: ?u16 = switch (address & 0xfffe) {
            0xae26 => facing,
            0xae2a => @bitCast(self.column),
            0xae2c => @bitCast(self.band),
            else => null,
        };
        const value = word orelse {
            self.unmodeled_reads += 1;
            return 0;
        };
        const b: u8 = @truncate(if (address & 1 == 0) value else value >> 8);
        return @bitCast(b);
    }

    // Messages ---------------------------------------------------------------------------

    fn resetLetters(self: *World) void {
        for (&self.letters, 0..) |*letter, i| {
            letter.next = if (i + 1 < letter_capacity) @intCast(i + 1) else null;
        }
        self.free_letter = 0;
    }

    /// Deliver a message, as the original does: an inactive recipient is woken if it can
    /// be (even when the message is then dropped), hits only reach a recipient in the
    /// sender's room and not a protected Conrad, and a full pool drops the message.
    pub fn send(self: *World, sender: u16, recipient: u16, message: vocabulary.Message) void {
        const to = &self.characters[recipient];
        if (!to.active) {
            if (!self.level.characters[recipient].wakes_on_message) return;
            to.active = true;
        }
        if (message.isHit()) {
            if (to.room != self.characters[sender].room) return;
            if (recipient == 0 and self.protection != 0) return;
        }
        const slot = self.free_letter orelse return;
        self.free_letter = self.letters[slot].next;
        self.letters[slot] = .{
            .sender = sender,
            .message = message,
            .next = self.inbox[recipient],
        };
        self.inbox[recipient] = slot;
    }

    /// The character's pending messages, newest first.
    pub fn mailbox(self: *const World, index: u16) Mailbox {
        return .{ .world = self, .next = self.inbox[index] };
    }

    pub const Mailbox = struct {
        world: *const World,
        next: ?u16,
        pub fn nextLetter(self: *Mailbox) ?Letter {
            const slot = self.next orelse return null;
            const letter = self.world.letters[slot];
            self.next = letter.next;
            return letter;
        }
    };

    fn clearInbox(self: *World, index: u16) void {
        while (self.inbox[index]) |slot| {
            self.inbox[index] = self.letters[slot].next;
            self.letters[slot].next = self.free_letter;
            self.free_letter = slot;
        }
    }
};
