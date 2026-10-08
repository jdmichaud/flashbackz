//! Extract one level: every rule group used by a placement becomes a behavior table, and every
//! placement becomes a character. Output is readable ZON; see DESIGN.md section 3.
const std = @import("std");
const flashbackz = @import("flashbackz");
const placement = flashbackz.content.placement;
const rule_table = flashbackz.content.rule_table;
const string_table = flashbackz.content.string_table;
const codes = @import("codes.zig");
const key = @import("key.zig");
const names = @import("names.zig");
const zon = @import("zon.zig");

pub const Input = struct {
    /// The level's name in the game, such as `city`.
    name: []const u8,
    placements: []const u8,
    rules: []const u8,
    labels: []const u8,
    score_awards: [16]u16,
    overlay: names.Overlay,
};

/// Receives each generated file.
pub const Output = struct {
    context: *anyopaque,
    put: *const fn (context: *anyopaque, path: []const u8, bytes: []const u8) anyerror!void,
};

/// Counts and notes worth a person's attention, one line per item.
pub const Report = struct {
    behaviors: usize = 0,
    named_behaviors: usize = 0,
    characters: usize = 0,
    dead_rules: usize = 0,
    ignored_arguments: usize = 0,
    notes: std.ArrayList(u8) = .empty,

    pub fn note(
        self: *Report,
        allocator: std.mem.Allocator,
        comptime format: []const u8,
        arguments: anytype,
    ) !void {
        try self.notes.print(allocator, format ++ "\n", arguments);
    }
};

const State = struct { animation: u16, name: []const u8, first: usize, count: usize };

const Behavior = struct {
    group: u16,
    rules: rule_table.Group,
    key: key.Key,
    named: ?names.Behavior,
    name: []const u8,
    file: []const u8,
    states: []State,
    links: [4]?[]const u8 = @splat(null),
    numbers: [4]?[]const u8 = @splat(null),

    fn stateName(self: Behavior, animation: u16) []const u8 {
        for (self.states) |state| if (state.animation == animation) return state.name;
        unreachable; // every target and start state is collected
    }
};

const Level = struct {
    arena: std.mem.Allocator,
    input: Input,
    table: placement.Table,
    report: *Report,
    behaviors: std.AutoArrayHashMapUnmanaged(u16, Behavior) = .empty,
    character_ids: [][]const u8 = &.{},
};

pub fn extract(arena: std.mem.Allocator, input: Input, output: Output, report: *Report) !void {
    var level: Level = .{
        .arena = arena,
        .input = input,
        .table = try placement.Table.init(input.placements),
        .report = report,
    };
    for (0..level.table.count) |index| {
        const record = try level.table.record(@intCast(index));
        if (level.behaviors.contains(record.rule_group)) continue;
        try level.behaviors.put(
            arena,
            record.rule_group,
            try collectBehavior(&level, record.rule_group),
        );
    }
    try nameBehaviors(&level);
    level.character_ids = try arena.alloc([]const u8, level.table.count);
    for (level.character_ids, 0..) |*id, index| id.* = try characterId(&level, @intCast(index));
    for (level.behaviors.values()) |*behavior| try classifyParameters(&level, behavior);
    for (level.behaviors.values()) |behavior| {
        var text: std.Io.Writer.Allocating = .init(arena);
        try writeBehavior(&level, behavior, &text.writer);
        const path = try std.fmt.allocPrint(
            arena,
            "{s}/behaviors/{s}.zon",
            .{ input.name, behavior.file },
        );
        try output.put(output.context, path, text.written());
    }
    var characters: std.Io.Writer.Allocating = .init(arena);
    try writeCharacters(&level, &characters.writer);
    try output.put(
        output.context,
        try std.fmt.allocPrint(arena, "{s}/characters.zon", .{input.name}),
        characters.written(),
    );
    report.behaviors += level.behaviors.count();
    report.characters += level.table.count;
}

fn collectBehavior(level: *Level, group_index: u16) !Behavior {
    const rules = try rule_table.group(level.input.rules, group_index);
    var animations: std.ArrayList(u16) = .empty;
    for (0..rules.count()) |index| {
        const rule = rules.at(index);
        for ([_]u16{ rule.source, rule.target }) |state| {
            if (std.mem.indexOfScalar(u16, animations.items, state) != null) continue;
            try animations.append(level.arena, state);
        }
    }
    const states = try level.arena.alloc(State, animations.items.len);
    var reachable: usize = 0;
    for (states, animations.items) |*state, animation| {
        var first: ?usize = null;
        for (0..rules.count()) |index| if (rules.at(index).source == animation) {
            first = index;
            break;
        };
        // Every target has rules in the floppy data; a state without rules only waits.
        const start = first orelse rules.count();
        var end = start;
        while (end < rules.count() and rules.at(end).source == animation) end += 1;
        reachable += end - start;
        state.* = .{ .animation = animation, .name = "", .first = start, .count = end - start };
    }
    if (reachable != rules.count()) {
        // The original scans a state's rules from its first one while the state matches, so a
        // later run of the same state can never be reached.
        level.report.dead_rules += rules.count() - reachable;
        const format = "{s}: rule group {d} has {d} unreachable rules (dropped)";
        try level.report.note(level.arena, format, .{
            level.input.name, group_index, rules.count() - reachable,
        });
    }
    return .{
        .group = group_index,
        .rules = rules,
        .key = key.compute(rules),
        .named = null,
        .name = "",
        .file = "",
        .states = states,
    };
}

fn nameBehaviors(level: *Level) !void {
    for (level.behaviors.values()) |*behavior| {
        behavior.named = level.input.overlay.behavior(&behavior.key);
        if (behavior.named) |named| {
            behavior.name = named.name;
            level.report.named_behaviors += 1;
        } else behavior.name = try std.fmt.allocPrint(
            level.arena,
            "behavior_{d}",
            .{behavior.group},
        );
        for (behavior.states, 0..) |*state, ordinal| {
            state.name = try std.fmt.allocPrint(level.arena, "state_{d}", .{state.animation});
            const named = behavior.named orelse continue;
            for (named.states) |entry| if (entry.ordinal == ordinal) {
                state.name = entry.name;
            };
        }
        for (behavior.states, 0..) |state, i| for (behavior.states[0..i]) |earlier| {
            if (std.mem.eql(u8, state.name, earlier.name)) return error.DuplicateStateName;
        };
    }
    // A behavior used by several rule groups of one level keeps its name with the group added.
    for (level.behaviors.values()) |*behavior| {
        var uses: usize = 0;
        for (level.behaviors.values()) |other| {
            uses += @intFromBool(std.mem.eql(u8, other.name, behavior.name));
        }
        behavior.file = if (uses == 1) behavior.name else try std.fmt.allocPrint(
            level.arena,
            "{s}_{d}",
            .{ behavior.name, behavior.group },
        );
    }
}

fn characterId(level: *Level, index: u16) ![]const u8 {
    if (index == 0) return "conrad";
    const record = try level.table.record(index);
    const behavior = level.behaviors.get(record.rule_group).?;
    var buffer: [64]u8 = undefined;
    const label = labelOf(level, record);
    const base = if (behavior.named != null)
        behavior.name
    else if (label.len != 0)
        zon.sanitize(&buffer, label)
    else
        codes.kindName(&buffer, @as(i16, record.kind));
    return std.fmt.allocPrint(
        level.arena,
        "{s}_{d}",
        .{ if (base.len == 0) "character" else base, index },
    );
}

fn labelOf(level: *Level, record: placement.Record) []const u8 {
    return string_table.copy(level.arena, level.input.labels, record.text_id) catch "";
}

/// Decide which placement parameters a behavior uses as links to other characters and which
/// as numbers, from the rules that can run.
fn classifyParameters(level: *Level, behavior: *Behavior) !void {
    var link_use: [4]bool = @splat(false);
    var number_use: [4]?[]const u8 = @splat(null);
    for (behavior.states) |state| for (state.first..state.first + state.count) |index| {
        const rule = behavior.rules.at(index);
        for ([_]rule_table.Operation{
            rule.conditions[0],
            rule.conditions[1],
            rule.effect,
        }) |operation| {
            const known = codes.lookup(operation.code) orelse continue;
            if (known.implicit) |p| {
                if (number_use[p.parameter] == null) number_use[p.parameter] = p.default_name;
            }
            const arg = operation.argument;
            switch (known.argument) {
                .send_to_link => |p| link_use[p] = true,
                .parameter_number => if (parameterIndex(arg, 0)) |p| {
                    if (number_use[p] == null) number_use[p] = "";
                },
                .parameter_link_and_amount => if (parameterIndex(arg, 1)) |p| {
                    link_use[p] = true;
                    if (number_use[p + 1] == null) number_use[p + 1] = "";
                },
                .parameter_link_pair => if (parameterIndex(arg, 1)) |p| {
                    link_use[p] = true;
                    link_use[p + 1] = true;
                },
                else => {},
            }
        }
    };
    const overlay: names.Behavior = behavior.named orelse .{ .key = "", .name = "" };
    for (0..4) |p| {
        const parameter: u2 = @intCast(p);
        // One parameter can serve as both: the same value names a character and a number.
        // Links the rules never use may still be named, for the engine's own reads.
        if (link_use[p] or overlayParameter(overlay.links, parameter) != null) {
            behavior.links[p] = overlayParameter(overlay.links, parameter) orelse
                try std.fmt.allocPrint(level.arena, "link_{d}", .{p});
        }
        if (number_use[p]) |default| {
            const fallback = if (default.len != 0)
                default
            else
                try std.fmt.allocPrint(level.arena, "number_{d}", .{p});
            behavior.numbers[p] = overlayParameter(overlay.numbers, parameter) orelse fallback;
        } else if (overlayParameter(overlay.numbers, parameter)) |name| {
            behavior.numbers[p] = name;
        }
        if (behavior.links[p] != null and behavior.numbers[p] != null) {
            try level.report.note(
                level.arena,
                "{s}: {s} uses parameter {d} both as a link and as a number",
                .{ level.input.name, behavior.file, p },
            );
        }
    }
}

fn parameterIndex(argument: i16, extra: u2) ?u2 {
    if (argument < 0 or argument + extra > 3) return null;
    return @intCast(argument);
}

fn overlayParameter(list: []const names.Parameter, parameter: u2) ?[]const u8 {
    for (list) |entry| if (entry.parameter == parameter) return entry.name;
    return null;
}

fn messageName(level: *Level, value: i16) ![]const u8 {
    if (level.input.overlay.message(level.input.name, value)) |name| return name;
    if (codes.engineMessage(value)) |name| return name;
    return if (value < 0)
        std.fmt.allocPrint(level.arena, "signal_minus_{d}", .{-@as(i32, value)})
    else
        std.fmt.allocPrint(level.arena, "signal_{d}", .{value});
}

fn writeBehavior(level: *Level, behavior: Behavior, out: *std.Io.Writer) !void {
    var w: zon.Writer = .{ .out = out };
    try out.print(
        \\// Generated by flashbackz-extract from the user's game files. Do not commit.
        \\// Original {s} rule group {d}. Name this behavior in the overlay with its key.
        \\
    , .{ level.input.name, behavior.group });
    try w.open(null);
    try w.line(".key = {f},", .{zon.string(&behavior.key)});
    try writeNameList(&w, "links", behavior.links);
    try writeNameList(&w, "numbers", behavior.numbers);
    try w.open("states");
    for (behavior.states, 0..) |state, ordinal| {
        try w.out.splatByteAll(' ', w.depth * 4);
        try w.out.print("{f} = .{{ // ordinal {d}\n", .{ zon.identifier(state.name), ordinal });
        w.depth += 1;
        try w.line(".animation = {d},", .{state.animation});
        try w.open("rules");
        for (state.first..state.first + state.count) |index| try writeRule(
            level,
            behavior,
            behavior.rules.at(index),
            &w,
        );
        try w.close();
        try w.close();
    }
    try w.close();
    try w.close();
}

fn writeNameList(w: *zon.Writer, field: []const u8, list: [4]?[]const u8) !void {
    var any = false;
    for (list) |entry| any = any or entry != null;
    if (!any) return;
    var count: usize = 0;
    for (list) |entry| count += @intFromBool(entry != null);
    try w.out.splatByteAll(' ', w.depth * 4);
    try w.out.print(".{s} = .{{", .{field});
    var first = true;
    for (list) |entry| if (entry) |name| {
        // zig fmt style: one element has no inner spaces, several do.
        try w.out.print(
            "{s}{f}",
            .{ if (first) (if (count == 1) "" else " ") else ", ", zon.identifier(name) },
        );
        first = false;
    };
    try w.out.writeAll(if (count == 1) "},\n" else " },\n");
}

fn writeRule(level: *Level, behavior: Behavior, rule: rule_table.Rule, w: *zon.Writer) !void {
    var checks: std.Io.Writer.Allocating = .init(level.arena);
    const first = rule.conditions[0];
    const second = rule.conditions[1];
    const second_reads_first = if (codes.lookup(second.code)) |known|
        known.argument == .kind_and
    else
        false;
    var count: usize = 0;
    for ([_]rule_table.Operation{ first, second }, 0..) |operation, slot| {
        if (operation.code == 0) continue;
        if (count != 0) try checks.writer.writeAll(", ");
        try writeOperation(
            level,
            behavior,
            operation,
            if (slot == 1 and second_reads_first) first.argument else null,
            &checks.writer,
        );
        count += 1;
    }
    const empty = count == 0 and
        rule.effect.code == 0 and
        rule.flags == 0 and
        rule.dx == 0 and
        rule.dy == 0 and
        rule.target == rule.source;
    if (empty) return w.line(".{{}},", .{});
    try w.open(null);
    // zig fmt style: one element has no inner spaces, several do.
    if (count == 1) try w.line(".when = .{{{s}}},", .{checks.written()});
    if (count > 1) try w.line(".when = .{{ {s} }},", .{checks.written()});
    if (rule.effect.code != 0) {
        var effect: std.Io.Writer.Allocating = .init(level.arena);
        try writeOperation(level, behavior, rule.effect, null, &effect.writer);
        try w.line(".then = {s},", .{effect.written()});
    }
    if (rule.flags & 1 != 0) try w.line(".turn = true,", .{});
    if (rule.flags & 2 != 0) try w.line(".damage = 1,", .{});
    if (rule.flags & 4 != 0) try w.line(".heal = 1,", .{});
    if (rule.flags & 8 != 0) try w.line(".kill = true,", .{});
    if (rule.flags >> 4 != 0) try w.line(
        ".score = {d},",
        .{level.input.score_awards[rule.flags >> 4]},
    );
    // The original's horizontal movement points toward the character's back.
    if (rule.dx != 0) try w.line(".forward = {d},", .{-@as(i16, rule.dx)});
    if (rule.dy != 0) try w.line(".down = {d},", .{rule.dy});
    if (rule.target != rule.source) try w.line(
        ".next = {f},",
        .{zon.identifier(behavior.stateName(rule.target))},
    );
    try w.close();
}

fn writeOperation(
    level: *Level,
    behavior: Behavior,
    operation: rule_table.Operation,
    first_argument: ?i16,
    out: *std.Io.Writer,
) !void {
    const known = codes.lookup(operation.code) orelse {
        try level.report.note(
            level.arena,
            "{s}: {s} uses unknown operation {d}",
            .{ level.input.name, behavior.file, operation.code },
        );
        return out.print(".{{ .unknown_{d} = {d} }}", .{ operation.code, operation.argument });
    };
    const name = zon.identifier(known.name);
    if (known.argument == .none) {
        if (operation.argument != 0) level.report.ignored_arguments += 1;
        return out.print("{f}", .{name});
    }
    var value: std.Io.Writer.Allocating = .init(level.arena);
    if (!try writeValue(
        level,
        behavior,
        known,
        operation.argument,
        first_argument,
        &value.writer,
    )) {
        return invalid(level, behavior, known, operation.argument, out);
    }
    const number = known.implicit orelse return out.print(
        ".{{ {f} = {s} }}",
        .{ name, value.written() },
    );
    // The original also reads one placement number; the table names it explicitly.
    const slot = behavior.numbers[number.parameter].?;
    try out.print(".{{ {f} = .{{ .{s} = {s}, .{s} = {f} }} }}", .{
        name, number.main_field, value.written(), number.field, zon.identifier(slot),
    });
}

/// Write an operation's argument; false when the original data holds an unexpected value.
fn writeValue(
    level: *Level,
    behavior: Behavior,
    known: codes.Operation,
    arg: i16,
    first_argument: ?i16,
    out: *std.Io.Writer,
) !bool {
    var buffer: [32]u8 = undefined;
    switch (known.argument) {
        .none => unreachable,
        .number => try out.print("{d}", .{arg}),
        .message => try out.print("{f}", .{zon.identifier(try messageName(level, arg))}),
        .send_to_link => |p| try out.print(".{{ .to = {f}, .message = {f} }}", .{
            zon.identifier(behavior.links[p].?), zon.identifier(try messageName(level, arg)),
        }),
        .parameter_number => {
            const p = parameterIndex(arg, 0) orelse return false;
            try out.print("{f}", .{zon.identifier(behavior.numbers[p].?)});
        },
        .parameter_link_and_amount => {
            const p = parameterIndex(arg, 1) orelse return false;
            try out.print(".{{ .purse = {f}, .amount = {f} }}", .{
                zon.identifier(behavior.links[p].?), zon.identifier(behavior.numbers[p + 1].?),
            });
        },
        .parameter_link_pair => |fields| {
            const p = parameterIndex(arg, 1) orelse return false;
            try out.print(".{{ .{s} = {f}, .{s} = {f} }}", .{
                fields[0],
                zon.identifier(behavior.links[p].?),
                fields[1],
                zon.identifier(behavior.links[p + 1].?),
            });
        },
        .character => {
            if (arg < 0 or arg >= level.character_ids.len) return false;
            try out.print("{f}", .{zon.identifier(level.character_ids[@intCast(arg)])});
        },
        .kind => try out.print("{f}", .{zon.identifier(codes.kindName(&buffer, arg))}),
        .button => try out.print(".{s}", .{switch (arg) {
            0 => "shift",
            1 => "enter",
            2 => "space",
            else => return false,
        }}),
        .hit_side => try out.print(".{s}", .{switch (arg) {
            0 => "from_behind",
            1 => "from_front",
            // Accepted as a front hit, but a shot never treats the character as waiting for it.
            else => "from_front_unannounced",
        }}),
        .height => try out.print(".{s}", .{switch (arg) {
            0 => "standing",
            1 => "crouched",
            else => return false,
        }}),
        .kind_and => |field| {
            const kind = zon.identifier(codes.kindName(&buffer, first_argument orelse 0));
            if (std.mem.eql(u8, field, "hit")) {
                const hit = zon.identifier(try messageName(level, arg));
                try out.print(".{{ .kind = {f}, .hit = {f} }}", .{ kind, hit });
            } else try out.print(".{{ .kind = {f}, .{s} = {d} }}", .{ kind, field, arg });
        },
    }
    return true;
}

fn invalid(
    level: *Level,
    behavior: Behavior,
    known: codes.Operation,
    arg: i16,
    out: *std.Io.Writer,
) !void {
    try level.report.note(
        level.arena,
        "{s}: {s} gives {s} the unexpected argument {d}",
        .{ level.input.name, behavior.file, known.name, arg },
    );
    try out.print(".{{ .{s}_raw = {d} }}", .{ known.name, arg });
}

fn writeCharacters(level: *Level, out: *std.Io.Writer) !void {
    var w: zon.Writer = .{ .out = out };
    try out.print(
        \\// Generated by flashbackz-extract from the user's game files. Do not commit.
        \\// Every placement of {s}, in the original update order.
        \\
    , .{level.input.name});
    try w.open(null);
    for (0..level.table.count) |index| {
        const record = try level.table.record(@intCast(index));
        const behavior = level.behaviors.get(record.rule_group).?;
        var buffer: [32]u8 = undefined;
        try w.open(level.character_ids[index]);
        try w.line(".placement = {d},", .{index});
        const label = labelOf(level, record);
        if (label.len != 0) try w.line(".label = {f},", .{zon.string(label)});
        try w.line(
            ".kind = {f},",
            .{zon.identifier(codes.kindName(&buffer, @as(i16, record.kind)))},
        );
        try w.line(".behavior = {f},", .{zon.identifier(behavior.file)});
        try w.line(".start = {f},", .{zon.identifier(behavior.stateName(record.initial_state))});
        if (record.room < 64) try w.line(".room = {d},", .{record.room}) else {
            if (record.room != 64) try level.report.note(
                level.arena,
                "{s}: placement {d} starts in room {d}",
                .{ level.input.name, index, record.room },
            );
            try w.line(".room = .outside,", .{});
        }
        try w.line(
            ".position = .{{ .x = {d}, .y = {d} }},",
            .{ record.position.x, record.position.y },
        );
        try w.line(".facing = .{s},", .{if (record.facing_right != 0) "right" else "left"});
        try w.line(".health = {d},", .{record.life});
        try w.line(".width = {d},", .{record.collision_width});
        try w.line(".active = {},", .{record.initially_active != 0});
        if (record.flags & 1 != 0) try w.line(".wakes_on_message = true,", .{});
        if (record.flags & 2 != 0) try w.line(".wakes_on_contact = true,", .{});
        if (record.flags & 4 != 0) try w.line(".wakes_when_near = true,", .{});
        const other_flags = record.flags & ~@as(u8, 7);
        if (other_flags != 0) try w.line(".other_flags = {d},", .{other_flags});
        try w.line(".minimum_difficulty = .{s},", .{switch (record.minimum_difficulty) {
            0 => "easy",
            1 => "normal",
            2 => "expert",
            else => "never",
        }});
        if (record.visual_flags & 3 != 0) try w.line(
            ".palette_bank = {d},",
            .{record.visual_flags & 3},
        );
        if (record.visual_flags & 8 != 0) try w.line(".behind_player = true,", .{});
        if (record.visual_flags & ~@as(u8, 11) != 0) try w.line(
            ".other_visual_flags = {d},",
            .{record.visual_flags & ~@as(u8, 11)},
        );
        if (record.contact_icon != 0) try w.line(".contact_icon = {d},", .{record.contact_icon});
        if (record.inventory_icon != 0) try w.line(
            ".inventory_icon = {d},",
            .{record.inventory_icon},
        );
        if (record.object_id != 0) try w.line(".object = {d},", .{record.object_id});
        if (record.reserved != 0) try w.line(".unknown_byte_29 = {d},", .{record.reserved});
        try writeParameters(level, behavior, record, &w);
        try w.close();
    }
    try w.close();
}

fn writeParameters(
    level: *Level,
    behavior: Behavior,
    record: placement.Record,
    w: *zon.Writer,
) !void {
    var has_links = false;
    for (behavior.links) |link| has_links = has_links or link != null;
    if (has_links) {
        try w.open("links");
        for (behavior.links, record.parameters) |link, value| if (link) |name| {
            if (value >= 0 and value < level.character_ids.len) {
                try w.line(
                    "{f} = {f},",
                    .{ zon.identifier(name), zon.identifier(level.character_ids[@intCast(value)]) },
                );
            } else try w.line("{f} = .none, // {d}", .{ zon.identifier(name), value });
        };
        try w.close();
    }
    var has_numbers = false;
    for (behavior.links, behavior.numbers, record.parameters) |link, number, value| {
        has_numbers = has_numbers or number != null or (link == null and value != 0);
    }
    if (!has_numbers) return;
    try w.open("numbers");
    for (behavior.links, behavior.numbers, record.parameters, 0..) |link, number, value, p| {
        if (number) |name| {
            try w.line("{f} = {d},", .{ zon.identifier(name), value });
        } else if (link == null and value != 0) try w.line(".parameter_{d} = {d},", .{ p, value });
    }
    try w.close();
}

const TestFiles = struct {
    files: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    arena: std.mem.Allocator,
    fn put(context: *anyopaque, path: []const u8, bytes: []const u8) anyerror!void {
        const self: *TestFiles = @ptrCast(@alignCast(context));
        try self.files.put(self.arena, path, try self.arena.dupe(u8, bytes));
    }
};

fn testRule(source: u16, target: u16, first: [2]i16, effect: [2]i16, flags: u8, dx: i8) [18]u8 {
    var r: [18]u8 = @splat(0);
    std.mem.writeInt(u16, r[0..2], source, .little);
    r[2] = @bitCast(dx);
    std.mem.writeInt(u16, r[4..6], target, .little);
    r[7] = @intCast(first[0]);
    r[8] = flags;
    r[9] = @intCast(effect[0]);
    std.mem.writeInt(i16, r[12..14], first[1], .little);
    std.mem.writeInt(i16, r[16..18], effect[1], .little);
    return r;
}

fn testPlacement(state: u16, group: u16, kind: u8, parameters: [4]i16, text: u16) [32]u8 {
    var r: [32]u8 = @splat(0);
    std.mem.writeInt(u16, r[0..2], state, .little);
    std.mem.writeInt(u16, r[6..8], group, .little);
    for (parameters, 0..) |value, i| std.mem.writeInt(i16, r[10 + i * 2 ..][0..2], value, .little);
    r[18] = kind;
    r[19] = 64;
    std.mem.writeInt(u16, r[30..32], text, .little);
    return r;
}

test "a synthetic level becomes named, linked, valid ZON with dead rules dropped" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Group 0: Conrad idles. Group 1: wait for message 20, reveal into the room in parameter 2;
    // seeing Conrad behind sends message 20 to the link in parameter 0, turns and moves back 16.
    // The last rule of state 5 is a second run that the original can never reach.
    const conrad_rules = testRule(1, 1, .{ 0, 0 }, .{ 0, 0 }, 0, 0);
    const guest_rules = testRule(5, 5, .{ 34, 20 }, .{ 87, 2 }, 0, 0) ++
        testRule(5, 6, .{ 121, 10 }, .{ 35, 20 }, 1, 16) ++
        testRule(6, 5, .{ 0, 0 }, .{ 75, 0 }, 0x12, 0) ++
        testRule(5, 5, .{ 0, 0 }, .{ 0, 0 }, 0, 0);
    var rules: std.ArrayList(u8) = .empty;
    try rules.appendSlice(arena, &.{ 2, 0, 8, 0, 0, 0, 28, 0, 0, 0 });
    try rules.appendSlice(arena, &([_]u8{ 1, 0 } ++ conrad_rules));
    try rules.appendSlice(arena, &([_]u8{ 4, 0 } ++ guest_rules));
    const placements = [_]u8{ 2, 0 } ++
        testPlacement(1, 0, 1, .{ 0, 0, 0, 0 }, 0) ++
        testPlacement(5, 1, 3, .{ 0, 0, 19, 0 }, 1);
    const labels = [_]u8{ 4, 0, 5, 0, 0, 'M', 'A', 'N', 0 };
    var score_awards: [16]u16 = @splat(0);
    score_awards[1] = 200;
    const overlay = try names.parse(std.testing.allocator, arena,
        \\.{ .messages = .{.{ .level = "all", .value = 20, .name = "call" }} }
    );
    var files: TestFiles = .{ .arena = arena };
    var report: Report = .{};
    try extract(arena, .{
        .name = "test",
        .placements = &placements,
        .rules = rules.items,
        .labels = &labels,
        .score_awards = score_awards,
        .overlay = overlay,
    }, .{ .context = &files, .put = TestFiles.put }, &report);
    try std.testing.expectEqual(@as(usize, 1), report.dead_rules);
    const guest = files.files.get("test/behaviors/behavior_1.zon").?;
    for ([_][]const u8{
        ".when = .{.{ .received = .call }},",
        ".then = .{ .reveal = .number_2 },",
        ".then = .{ .send = .{ .to = .link_0, .message = .call } },",
        ".turn = true,",
        ".forward = -16,",
        ".damage = 1,",
        ".score = 200,",
        ".then = .remove,",
    }) |expected| try std.testing.expect(std.mem.indexOf(u8, guest, expected) != null);
    const characters = files.files.get("test/characters.zon").?;
    for ([_][]const u8{
        ".man_1 = .{",
        ".label = \"MAN\",",
        ".link_0 = .conrad,",
        ".number_2 = 19,",
        ".start = .state_5,",
    }) |expected| {
        try std.testing.expect(std.mem.indexOf(u8, characters, expected) != null);
    }
    for (files.files.values()) |bytes| {
        var tree = try std.zig.Ast.parse(
            std.testing.allocator,
            try arena.dupeSentinel(u8, bytes, 0),
            .{ .mode = .zon },
        );
        defer tree.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    }
}
