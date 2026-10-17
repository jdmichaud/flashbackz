//! The screen of a level: how the original presents the engine's state after each update
//! (flashback-re docs/rules/engine-presentation.md, engine-ending-zoom.md).
const std = @import("std");
const behavior = @import("../behavior/root.zig");
const Kind = behavior.vocabulary.Kind;
const level_pack = @import("../content/level_pack.zig");
const character_art = @import("../content/character_art.zig");
const sprite = @import("../content/sprite.zig");
const palette = @import("../content/palette.zig");
const sprite_renderer = @import("../render/sprite.zig");
const text_renderer = @import("../render/text.zig");
const World = behavior.world.World;
const data_set = behavior.data_set;
const contacts = behavior.contacts;

pub const width = 256;
pub const height = 224;
pub const pixel_count = width * height;

/// What the screen keeps between updates.
pub const Screen = struct {
    /// The background page: the view room, with the HUD icon painted into it.
    background: [pixel_count]u8 = @splat(0),
    /// Background pixels that hide sprites: the room's foreground and the HUD icon.
    foreground: [pixel_count]bool = @splat(false),
    /// The frame being composed (the back page), the picture on display and the colors it is
    /// shown with.
    picture: [pixel_count]u8 = @splat(0),
    displayed: [pixel_count]u8 = @splat(0),
    colors: palette.Palette = @splat(.{ .r = 0, .g = 0, .b = 0 }),
    /// Room loads already shown.
    room_loads: u32 = 0,
    /// After a room load, the screen keeps the old picture for two updates and shows the new
    /// room, with its colors, on the third. The zoom's delayed entry uses the same countdown.
    room_countdown: u8 = 0,
    deferred: bool = false,
    /// This update composed no frame (the first updates after a room load).
    hidden: bool = false,
    hud_icon: ?u8 = null,
    /// The enemy library loaded, and the last rule group (here: behavior) resolved to one.
    library: ?data_set.SpriteLibrary = null,
    library_behavior: ?u16 = null,
    /// Frames left showing the level's password; none in demos.
    password_frames: u8,
    /// A notice of ours, as GAME SAVED (PLAN GS-5), and the frames left showing it.
    notice: []const u8 = "",
    notice_frames: u8 = 0,
    checkpoint_saves: u32 = 0,
    /// "COMPLETED" shows while Conrad touches the save terminal after saving.
    completed: bool = false,
    /// A world message waits until the room shows, then pages over the frame it froze.
    pending_message: ?u16 = null,
    message: ?ShownMessage = null,
    /// The frame under the message.
    under_message: [pixel_count]u8 = @splat(0),
    /// Pages alternate between the two video pages. After each flip, the page about to be
    /// drawn gets the texts and icons it showed earlier wiped with the background, which then
    /// holds the frozen frame's message area (16, 26, 128x32).
    pages: [2][pixel_count]u8 = undefined,
    page_rects: [2]Rects = .{.{}, .{}},
    page_buffer: u1 = 0,
    message_background: [pixel_count]u8 = undefined,
    /// The rectangles of the texts and icons drawn this frame and the previous one.
    frame_rects: Rects = .{},
    previous_rects: Rects = .{},
    /// A new HUD icon reaches the picture when it is flipped, after any message.
    hud_unshown: bool = false,
    /// The screen shake moves the displayed picture down by 0 to 3 rows. Each flip takes the
    /// value computed after the previous one.
    shake_rows: u2 = 0,
    next_shake_rows: u2 = 0,
    /// The icon beside the message: what Conrad touched while one was pending (it can be
    /// stale, as in the original).
    message_icon: u8 = 0,
    zoom: Zoom = .{},
    message_left_zoom: bool = false,

    pub const ShownMessage = struct {
        number: u16,
        page: usize = 0,
    };

    const Rect = struct {
        x: i32,
        y: i32,
        w: i32,
        h: i32,
    };
    const Rects = struct {
        items: [16]Rect = undefined,
        count: u8 = 0,

        fn add(self: *Rects, rect: Rect) void {
            if (self.count == self.items.len) return;
            self.items[self.count] = rect;
            self.count += 1;
        }
    };

    pub fn init(demo: bool) Screen {
        return .{ .password_frames = if (demo) 0 else 150 };
    }

    /// Composes the frame for the engine's state after an update (the original's draw
    /// section). A world message opens here; the frame is shown by `flip`.
    pub fn draw(
        self: *Screen,
        pack: *const level_pack.Pack,
        messages: data_set.Messages,
        world: *const World,
    ) !void {
        if (world.requests.world_message) |number| {
            if (number >= 0) {
                self.pending_message = @intCast(number);
            }
        }
        if (world.room_loads != self.room_loads) {
            self.room_loads = world.room_loads;
            self.loadRoom(pack, world);
        }
        if (world.checkpoint_saves != self.checkpoint_saves) {
            self.checkpoint_saves = world.checkpoint_saves;
            self.completed = true;
        }
        self.zoom.hits(world);
        self.hidden = self.room_countdown > 1;
        if (self.hidden) return;
        @memcpy(&self.picture, &self.background);
        var lists: Lists = .{};
        self.queueAll(pack, world, &lists);
        try self.render(&lists, world);
        self.frame_rects = .{};
        try self.drawLabel(pack, world);
        try self.drawPassword(pack);
        try self.drawNotice(pack);
        try self.paintHudIcon(pack, world);
        if (self.pending_message) |number| {
            self.pending_message = null;
            if (number < messages.len and messages[number].len != 0) {
                try self.openMessage(pack, messages, number);
            }
        }
        self.previous_rects = self.frame_rects;
    }

    /// After the draw section, also for hidden frames: the zoom's timers count down.
    pub fn afterDraw(self: *Screen) void {
        self.zoom.countDown();
    }

    /// Shows the composed frame (the original's present): the new HUD icon, the zoom's entry or
    /// exit and its doubled window, then the flip, which a room load or the zoom's delayed
    /// entry can hold back, and the room's colors after a room load.
    pub fn flip(self: *Screen, pack: *const level_pack.Pack, world: *const World) void {
        self.showHudIcon(pack);
        if (self.zoom.enter) {
            if (self.zoom.delayed) {
                self.zoom.delayed = false;
                self.room_countdown = 2;
                self.deferred = true;
            } else {
                self.zoom.enter = false;
                self.zoom.begin(world);
                @memcpy(&self.displayed, &self.zoom.page);
            }
        } else if (self.zoom.leave) {
            // Leaving shows this update's frame at once; nothing else is flipped.
            self.zoom.leave = false;
            self.zoom.on = false;
            @memcpy(&self.displayed, &self.picture);
            return;
        }
        if (self.zoom.on) {
            self.zoom.follow(world);
            self.zoom.blit(&self.picture);
        }
        if (self.deferred) {
            self.room_countdown -|= 1;
            if (self.room_countdown != 0) return;
        }
        @memcpy(&self.displayed, if (self.zoom.on) &self.zoom.page else &self.picture);
        self.shake_rows = self.next_shake_rows;
        self.next_shake_rows = @truncate(@as(u8, @bitCast(world.shake)));
        if (self.deferred) {
            self.deferred = false;
            self.setRoomColors(pack, world.view_room);
        }
    }

    /// The inventory leaves the zoom while it is open and asks for it back, one update late.
    pub fn leaveZoomFor(self: *Screen) bool {
        if (!self.zoom.on) return false;
        self.zoom.on = false;
        @memcpy(&self.displayed, &self.picture);
        return true;
    }

    pub fn returnToZoom(self: *Screen) void {
        self.zoom.enter = true;
        self.zoom.delayed = true;
    }

    /// Turns the message's page. False when it was the last: the frame shows without it.
    pub fn nextMessagePage(
        self: *Screen,
        pack: *const level_pack.Pack,
        messages: data_set.Messages,
    ) !bool {
        const shown = &(self.message orelse return false);
        shown.page += 1;
        if (shown.page < messages[shown.number].len) {
            try self.drawMessagePage(pack, messages);
            return true;
        }
        self.message = null;
        @memcpy(&self.picture, &self.under_message);
        @memcpy(&self.displayed, &self.under_message);
        if (self.message_left_zoom) {
            self.message_left_zoom = false;
            self.returnToZoom();
        }
        return false;
    }

    /// The message freezes the frame: the background takes its message area, and both video
    /// pages hold it, each with the texts drawn into it in the last two frames.
    fn openMessage(
        self: *Screen,
        pack: *const level_pack.Pack,
        messages: data_set.Messages,
        number: u16,
    ) !void {
        // The message is shown at full size; the zoom comes back after it.
        self.message_left_zoom = self.leaveZoomFor();
        @memcpy(&self.under_message, &self.picture);
        @memcpy(&self.message_background, &self.background);
        for (26..58) |row| {
            @memcpy(
                self.message_background[row * width + 16..][0..128],
                self.picture[row * width + 16..][0..128],
            );
        }
        self.pages = .{ self.picture, self.picture };
        self.page_rects = .{ self.frame_rects, self.previous_rects };
        self.page_buffer = 0;
        self.message = .{ .number = number };
        try self.drawMessagePage(pack, messages);
    }

    /// The page's lines centered on x = 88 from y = 26, with the icon at (80, 8), drawn into
    /// its video page, which is then shown; the other page is wiped for the next one.
    fn drawMessagePage(
        self: *Screen,
        pack: *const level_pack.Pack,
        messages: data_set.Messages,
    ) !void {
        const shown = self.message.?;
        const target = &self.pages[self.page_buffer];
        const rects = &self.page_rects[self.page_buffer];
        if (iconFrame(pack, self.message_icon)) |frame| {
            drawIcon(target, rects, frame, 80, 8);
        }
        for (messages[shown.number][shown.page], 0..) |line, row| {
            const x = 88 - 4 * @as(i32, @intCast(line.text.len));
            const y = 26 + 8 * @as(i32, @intCast(row));
            try drawText(target, rects, pack, line.text, x, y, line.ink);
        }
        @memcpy(&self.displayed, target);
        self.page_buffer = ~self.page_buffer;
        const other = &self.pages[self.page_buffer];
        const old = &self.page_rects[self.page_buffer];
        for (old.items[0..old.count]) |rect| {
            restore(other, &self.message_background, rect);
        }
        old.* = .{};
    }

    /// What the display shows of `picture`: shaken down by the shake rows, the rows above
    /// blank.
    pub fn display(
        self: *const Screen,
        picture: *const [pixel_count]u8,
        shown: *[pixel_count]u8,
    ) void {
        const offset = @as(usize, self.shake_rows) * width;
        @memset(shown[0..offset], 0);
        @memcpy(shown[offset..], picture[0..pixel_count - offset]);
    }

    fn loadRoom(self: *Screen, pack: *const level_pack.Pack, world: *const World) void {
        const room = world.view_room;
        if (self.zoom.on) {
            self.zoom.snap(world);
        }
        if (pack.room(room)) |art| {
            @memcpy(&self.background, art.image.pixels);
            @memcpy(&self.foreground, art.foreground);
        } else {
            @memset(&self.background, 0);
            @memset(&self.foreground, false);
        }
        self.hud_icon = null;
        self.room_countdown = 3;
        self.deferred = true;
    }

    /// The new room's colors, set after its first frame shows. The enemy library's block and
    /// the film blocks are left as they are.
    fn setRoomColors(self: *Screen, pack: *const level_pack.Pack, room: u8) void {
        const art = pack.room(room) orelse return;
        for ([_]usize{ 0, 1, 2, 3, 4, 8, 9, 10, 11, 14, 15 }) |block| {
            @memcpy(self.colors[block * 16..][0..16], art.colors[block * 16..][0..16]);
        }
    }

    /// The selected item's icon is painted into the background, where it hides sprites. It is
    /// painted over the previous one without clearing, and stays when the inventory empties.
    fn paintHudIcon(self: *Screen, pack: *const level_pack.Pack, world: *const World) !void {
        const item = world.characters[0].first_item orelse return;
        const icon = world.level.characters[item].inventory_icon;
        if (self.hud_icon == icon) return;
        self.hud_icon = icon;
        const frame = iconFrame(pack, icon) orelse return;
        for (0..16) |row| {
            for (0..16) |column| {
                const pixel = frame.image.pixels[row * 16 + column];
                if (pixel == 0) continue;
                const at = (8 + row) * width + 232 + column;
                self.background[at] = 0xa0 | pixel;
                self.foreground[at] = true;
            }
        }
        self.hud_unshown = true;
    }

    /// The new HUD icon is drawn onto the picture just before it is flipped (and zoomed).
    fn showHudIcon(self: *Screen, pack: *const level_pack.Pack) void {
        if (!self.hud_unshown) return;
        self.hud_unshown = false;
        const frame = iconFrame(pack, self.hud_icon orelse return) orelse return;
        var unrecorded: Rects = .{};
        drawIcon(&self.picture, &unrecorded, frame, 232, 8);
    }

    // Characters --------------------------------------------------------------------------

    const Layer = enum { behind, conrad, normal, overlay };

    const Entry = struct {
        frame: *const sprite.Frame,
        x: i32,
        y: i32,
        mirrored: bool,
        bank: u4,
        character: u16,
    };

    const Lists = struct {
        entries: [4][64]Entry = undefined,
        counts: [4]u8 = @splat(0),

        fn add(self: *Lists, layer: Layer, entry: Entry) void {
            const list = @backingInt(layer);
            if (self.counts[list] == self.entries[list].len) return;
            self.entries[list][self.counts[list]] = entry;
            self.counts[list] += 1;
        }
    };

    /// The view room's characters, then those of the rooms above, below, left and right whose
    /// position reaches into the view.
    fn queueAll(
        self: *Screen,
        pack: *const level_pack.Pack,
        world: *const World,
        lists: *Lists,
    ) void {
        const view = world.view_room;
        if (view >= 64) return;
        self.queueRoom(pack, world, lists, view, .view);
        self.queueRoom(pack, world, lists, world.grid.rawLink(view, .up), .up);
        self.queueRoom(pack, world, lists, world.grid.rawLink(view, .down), .down);
        self.queueRoom(pack, world, lists, world.grid.rawLink(view, .left), .left);
        self.queueRoom(pack, world, lists, world.grid.rawLink(view, .right), .right);
    }

    const Strip = enum { view, up, down, left, right };

    fn queueRoom(
        self: *Screen,
        pack: *const level_pack.Pack,
        world: *const World,
        lists: *Lists,
        room: u8,
        strip: Strip,
    ) void {
        if (room >= 64) return;
        var next = world.room_lists[room];
        while (next) |index| : (next = world.characters[index].next_in_room) {
            const character = world.characters[index];
            const offset: [2]i32 = switch (strip) {
                .view => .{ 0, 0 },
                .up => if (character.y > @as(i16, if (isEnemy(world, index)) 216 else 176))
                    .{ 0, -216 }
                else
                    continue,
                .down => if (character.y < 48) .{ 0, 216 } else continue,
                .left => if (character.x > 224) .{ -256, 0 } else continue,
                .right => if (character.x <= 32) .{ 256, 0 } else continue,
            };
            self.queue(pack, world, lists, index, offset[0], offset[1]);
        }
    }

    fn queue(
        self: *Screen,
        pack: *const level_pack.Pack,
        world: *const World,
        lists: *Lists,
        index: u16,
        dx: i32,
        dy: i32,
    ) void {
        const character = world.characters[index];
        const definition = world.level.characters[index];
        const look = character.look;
        const key: character_art.Key = .{ .sprite = look.sprite, .composed = look.composed };
        const x = @as(i32, character.x) + dx;
        const y = @as(i32, character.y) + dy;
        if (look.composed) {
            // Composed object art: one of the room's four blocks, never culled here.
            const frame = pack.characters.get(key) orelse return;
            const layer: Layer = if (definition.kind.matches(.overlay))
                .overlay
            else if (definition.behind_player) .behind else .normal;
            lists.add(layer, .{
                .frame = frame,
                .x = x + 8,
                .y = y + 2,
                .mirrored = look.mirrored,
                .bank = @intCast(definition.palette_bank & 3),
                .character = index,
            });
            return;
        }
        if (index != 0 and !self.libraryReady(pack, world, index)) return;
        const frame = pack.characters.get(key) orelse return;
        const w: i32 = frame.image.width;
        const left = if (look.mirrored) x + frame.origin_x - w else x - frame.origin_x;
        const top = y - frame.origin_y + 2;
        if (left <= -32 or left >= 256 or top <= -48 or top >= 224) return;
        const layer: Layer = if (index == 0)
            .conrad
        else if (definition.behind_player) .behind else .normal;
        lists.add(layer, .{
            .frame = frame,
            .x = x + 8,
            .y = y + 2,
            .mirrored = look.mirrored,
            .bank = if (definition.palette_bank & 3 == 3) 5 else 4,
            .character = index,
        });
    }

    /// Enemies draw library sprites only once their library is loaded. The library follows the
    /// enemies queued in the view room; elsewhere only the last group resolved is drawn.
    fn libraryReady(
        self: *Screen,
        pack: *const level_pack.Pack,
        world: *const World,
        index: u16,
    ) bool {
        const definition = world.level.characters[index];
        const library = definition.sprite_library orelse return true;
        if (self.library_behavior == definition.behavior) return true;
        if (world.characters[index].room != world.view_room) return false;
        if (library == .none) return false;
        self.library_behavior = definition.behavior;
        if (self.library == library) return true;
        self.library = library;
        // The library's colors take effect at once.
        @memcpy(self.colors[0x50..0x60], &pack.library_colors[@backingInt(library)]);
        return true;
    }

    /// Bottom to top: the behind list, Conrad, the others, then overlay art. Within a list the
    /// character queued first ends on top. Conrad blinks while his protection is odd.
    fn render(self: *Screen, lists: *const Lists, world: *const World) !void {
        for (std.enums.values(Layer)) |layer| {
            const list = @backingInt(layer);
            var k = lists.counts[list];
            while (k > 0) {
                k -= 1;
                const entry = lists.entries[list][k];
                if (layer == .conrad and world.protection & 1 != 0) continue;
                try sprite_renderer.draw(
                    &self.picture,
                    width,
                    height,
                    entry.frame,
                    entry.x,
                    entry.y,
                    .{
                        .palette_bank = entry.bank,
                        .facing = if (entry.mirrored) .mirrored else .original,
                        .foreground = if (layer == .overlay) .overwrite else .respect,
                        .occlusion = &self.foreground,
                    },
                );
            }
        }
    }

    // Texts --------------------------------------------------------------------------------

    /// The icon and name of what Conrad touches: an item (kind 3) in his first cell, else a
    /// character of kind 5 or 9; both searches also take kind -1, as the original compares bytes.
    /// Touching anything ends the password display.
    fn drawLabel(self: *Screen, pack: *const level_pack.Pack, world: *const World) !void {
        const found = labelTarget(world) orelse {
            self.completed = false;
            return;
        };
        self.password_frames = 0;
        if (self.pending_message != null) {
            self.message_icon = found.icon - 1;
            self.completed = false;
            return;
        }
        const rects = &self.frame_rects;
        if (iconFrame(pack, found.icon - 1)) |frame| {
            drawIcon(&self.picture, rects, frame, 80, 8);
        }
        const name = world.level.characters[found.character].label;
        const x = 88 - 4 * @as(i32, @intCast(name.len));
        try drawText(&self.picture, rects, pack, name, x, 26, 0xe6);
        if (found.icon != 3) {
            self.completed = false;
        } else if (self.completed) {
            try drawText(&self.picture, rects, pack, "COMPLETED", 88 - 4 * 9, 34, 0xe6);
        }
    }

    /// The inventory loop also draws the password, so its polls count it down too.
    pub fn countPasswordFrame(self: *Screen) void {
        self.password_frames -|= 1;
    }

    /// Shows `notice` for two seconds, under the password while it shows.
    pub fn showNotice(self: *Screen, notice: []const u8) void {
        self.notice = notice;
        self.notice_frames = 70;
    }

    fn drawNotice(self: *Screen, pack: *const level_pack.Pack) !void {
        if (self.notice_frames == 0) return;
        self.notice_frames -= 1;
        const x = 128 - 4 * @as(i32, @intCast(self.notice.len));
        try drawText(
            &self.picture,
            &self.frame_rects,
            pack,
            self.notice,
            x,
            if (self.password_frames == 0) 16 else 28,
            0xe7,
        );
    }

    fn drawPassword(self: *Screen, pack: *const level_pack.Pack) !void {
        if (self.password_frames == 0) return;
        self.password_frames -= 1;
        if (self.password_frames == 0) return;
        const text = std.mem.sliceTo(&pack.password, 0);
        const x = 128 - 4 * @as(i32, @intCast(text.len));
        try drawText(&self.picture, &self.frame_rects, pack, text, x, 16, 0xe7);
    }
};

/// Draws text and records its rectangle, as the original does for later restoring.
fn drawText(
    target: *[pixel_count]u8,
    rects: *Screen.Rects,
    pack: *const level_pack.Pack,
    text: []const u8,
    x: i32,
    y: i32,
    ink: u8,
) !void {
    try text_renderer.draw(target, width, height, &pack.font, text, x, y, .{
        .foreground = ink,
        .shadow = 0xe2,
        .palette_bank = 14,
    });
    rects.add(.{ .x = x, .y = y, .w = 8 * @as(i32, @intCast(text.len)), .h = 8 });
}

/// Copies a rectangle from `source`, clipped to the screen.
fn restore(target: *[pixel_count]u8, source: *const [pixel_count]u8, rect: Screen.Rect) void {
    const x0: usize = @intCast(std.math.clamp(rect.x, 0, width));
    const x1: usize = @intCast(std.math.clamp(rect.x + rect.w, 0, width));
    const y0: usize = @intCast(std.math.clamp(rect.y, 0, height));
    const y1: usize = @intCast(std.math.clamp(rect.y + rect.h, 0, height));
    if (x1 <= x0) return;
    for (y0..y1) |row| {
        const line = row * width;
        @memcpy(target[line + x0..line + x1], source[line + x0..line + x1]);
    }
}

const Label = struct {
    icon: u8,
    character: u16,
};

/// The first search looks for an item (kind 3) among the characters in Conrad's first cell,
/// newest first, Conrad included. If none has an icon, a second search for kinds 5 and 9 starts
/// from the first cell of the last character the first search examined.
fn labelTarget(world: *const World) ?Label {
    var last: u16 = 0;
    const item = search(world, 0, &.{ .interactive, .any }, &last);
    if (item) |found| {
        if (positive(found.icon)) return found;
    }
    const other = search(world, last, &.{ .any, @fromBackingInt(5), @fromBackingInt(9) }, &last);
    if (other) |found| {
        if (positive(found.icon)) return found;
    }
    return null;
}

/// Icons compare as signed bytes.
fn positive(icon: u8) bool {
    return @as(i8, @bitCast(icon)) > 0;
}

fn search(world: *const World, who: u16, kinds: []const Kind, last: *u16) ?Label {
    const slot = world.characters[who].contact;
    if (slot == contacts.no_slot) return null;
    var occupants = world.contacts.occupants(slot);
    while (occupants.nextEntry()) |entry| {
        last.* = entry.character;
        const definition = world.level.characters[entry.character];
        for (kinds) |kind| {
            if (definition.kind.matches(kind)) break;
        } else {
            continue;
        }
        return .{ .icon = definition.contact_icon, .character = entry.character };
    }
    return null;
}

fn isEnemy(world: *const World, index: u16) bool {
    return world.level.characters[index].kind.matches(.enemy);
}

pub fn iconFrame(pack: *const level_pack.Pack, icon: u8) ?*const sprite.Frame {
    if (icon >= pack.icons.len) return null;
    return &pack.icons[icon];
}

/// Icons draw their nonzero pixels with the icon colors, over anything.
fn drawIcon(
    picture: *[pixel_count]u8,
    rects: *Screen.Rects,
    frame: *const sprite.Frame,
    x: usize,
    y: usize,
) void {
    for (0..16) |row| {
        for (0..16) |column| {
            const pixel = frame.image.pixels[row * 16 + column];
            if (pixel != 0) {
                picture[(y + row) * width + x + column] = 0xa0 | pixel;
            }
        }
    }
    rects.add(.{ .x = @intCast(x), .y = @intCast(y), .w = 16, .h = 16 });
}

/// The zoom view (Game Options "Zoom": off, on or automatic): a 128x80 window of the frame,
/// doubled to 256x160 at y = 24, that follows Conrad or, for 30 updates, a character just hit
/// (flashback-re docs/rules/engine-ending-zoom.md 6-10).
pub const Zoom = struct {
    on: bool = false,
    /// The automatic option: hits on Conrad or an enemy turn the zoom on for 40 updates.
    automatic: bool = false,
    /// Requests served by the next flip; a delayed entry waits one more update.
    enter: bool = false,
    leave: bool = false,
    delayed: bool = false,
    /// The window's top-left corner in the frame, and where the blit last took it from.
    camera_x: i16 = 0,
    camera_y: i16 = 0,
    blit_x: i16 = 0,
    blit_y: i16 = 0,
    /// Updates before an automatic zoom leaves, and before the camera returns to Conrad.
    leave_timer: u8 = 0,
    follow_timer: u8 = 0,
    /// The character the camera follows; 0 is Conrad.
    target: u16 = 0,
    /// The displayed zoom page: black borders, the doubled window between them.
    page: [pixel_count]u8 = @splat(0),

    const window_width = 128;
    const window_height = 80;
    const top = 24;
    const border = 0xe0;

    /// The options menu's Zoom row: 0 off, 1 on, 2 automatic.
    pub fn row(self: Zoom) u2 {
        if (self.automatic) return 2;
        return @intFromBool(self.on);
    }

    /// Closing the options menu applies its Zoom row.
    pub fn setRow(self: *Zoom, chosen: u2) void {
        if (chosen == 2) {
            self.automatic = true;
            if (self.on) {
                self.on = false;
                self.leave = true;
            }
            return;
        }
        self.automatic = false;
        if (self.on == (chosen == 1)) return;
        if (self.on) {
            self.on = false;
            self.leave = true;
        } else {
            self.on = true;
            self.enter = true;
        }
    }

    /// Hits delivered this update: the camera follows the character hit for 30 updates; the
    /// automatic zoom turns on for hits on Conrad or an enemy, until 40 updates after the last.
    fn hits(self: *Zoom, world: *const World) void {
        for (world.requests.hits[0..world.requests.hit_count]) |recipient| {
            if (self.automatic) {
                const kind = world.level.characters[recipient].kind;
                if (!kind.matches(.player) and !kind.matches(.enemy)) continue;
                if (!self.on) {
                    self.enter = true;
                }
                self.leave_timer = 40;
            }
            self.target = recipient;
            self.follow_timer = 30;
        }
    }

    fn countDown(self: *Zoom) void {
        if (self.leave_timer != 0) {
            self.leave_timer -= 1;
            if (self.leave_timer == 0 and self.on) {
                self.leave = true;
            }
        }
        if (self.follow_timer != 0) {
            self.follow_timer -= 1;
            if (self.follow_timer == 0) {
                self.target = 0;
            }
        }
    }

    /// Entering fills the page black and puts the window straight on its target.
    fn begin(self: *Zoom, world: *const World) void {
        @memset(&self.page, border);
        self.on = true;
        self.snap(world);
    }

    fn snap(self: *Zoom, world: *const World) void {
        const aim = self.goal(world);
        self.camera_x = aim.x;
        self.camera_y = aim.y;
    }

    /// Where the window wants to be: Conrad looking into the open side, or a followed
    /// character placed by Conrad's facing. A target outside the view room gives way to Conrad.
    fn goal(self: *Zoom, world: *const World) struct { x: i16, y: i16, carried: bool } {
        if (world.characters[self.target].room != world.view_room) {
            self.target = 0;
        }
        const target = world.characters[self.target];
        const following = self.target != 0;
        const near = target.x - 12;
        const far = target.x + 22 - window_width;
        const x = if (world.characters[0].facing_right == following) far else near;
        return .{
            .x = std.math.clamp(x, 0, width - window_width),
            .y = std.math.clamp(target.y - 24 - window_height / 2, 0, height - window_height),
            .carried = target.owner != null,
        };
    }

    /// The window moves toward its goal in steps that grow with the distance, never past it.
    fn follow(self: *Zoom, world: *const World) void {
        const aim = self.goal(world);
        const dx = @abs(aim.x - self.camera_x);
        const step_x: i16 = if (dx < 4)
            0
        else if (dx < 8)
            1
        else if (dx < 16)
            2
        else if (self.follow_timer != 0)
            8
        else
            4;
        const dy = @abs(aim.y - self.camera_y);
        // A carried target has a narrower dead zone; no hit target is carried in practice.
        const dead_zone: u16 = if (aim.carried) 2 else 4;
        const step_y: i16 = if (dy < dead_zone) 0 else if (dy < 8) 2 else if (dy < 16) 4 else 8;
        self.camera_x = toward(self.camera_x, aim.x, step_x);
        self.camera_y = toward(self.camera_y, aim.y, step_y);
        self.blit_x = self.camera_x;
        self.blit_y = self.camera_y;
    }

    fn toward(from: i16, to: i16, step: i16) i16 {
        return if (from < to) from + step else if (from > to) from - step else from;
    }

    /// The window, doubled, between the borders. The original's clamp shows column 124 when the
    /// camera is at 128, and row 143 at 144.
    fn blit(self: *Zoom, picture: *const [pixel_count]u8) void {
        const sx: usize = if (self.blit_x >= width - window_width)
            124
        else
            @intCast(@max(self.blit_x, 0));
        const sy: usize = if (self.blit_y >= height - window_height)
            height - window_height - 1
        else
            @intCast(@max(self.blit_y, 0));
        for (0..2 * window_height) |y| {
            for (0..width) |x| {
                self.page[(top + y) * width + x] = picture[(sy + y / 2) * width + sx + x / 2];
            }
        }
    }
};
