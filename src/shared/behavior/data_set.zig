//! Loads one level of the extracted data set (DESIGN.md section 3) into typed, immutable
//! behaviors and characters. Every name is resolved here; the engine works with indices.
const std = @import("std");
const vocabulary = @import("vocabulary.zig");
const Zoir = std.zig.Zoir;
const Node = Zoir.Node;

pub const Difficulty = enum { easy, normal, expert, never };
pub const Facing = enum { left, right };

pub const Character = struct {
    name: []const u8,
    placement: u16,
    label: []const u8 = "",
    kind: vocabulary.Kind,
    behavior: u16,
    start: u16,
    /// Null while the character is outside the world (hidden until revealed).
    room: ?u8,
    x: i16,
    y: i16,
    facing: Facing,
    health: i16,
    width: u8,
    active: bool,
    wakes_on_message: bool = false,
    /// Wakes when another character shares one of its cells.
    wakes_on_contact: bool = false,
    wakes_when_near: bool = false,
    other_flags: u8 = 0,
    minimum_difficulty: Difficulty,
    palette_bank: u8 = 0,
    behind_player: bool = false,
    other_visual_flags: u8 = 0,
    contact_icon: u8 = 0,
    inventory_icon: u8 = 0,
    object: u8 = 0,
    unknown_byte_29: u8 = 0,
    /// By position in the behavior's `links`; null when the link names no character.
    links: [4]?vocabulary.Character = @splat(null),
    /// By position in the behavior's `numbers`.
    numbers: [4]i16 = @splat(0),
    /// Placement numbers no rule uses, by original parameter slot.
    unused_parameters: [4]i16 = @splat(0),
};

pub const Level = struct {
    behaviors: []const vocabulary.Behavior,
    characters: []const Character,
    /// Message names by id; ids not used by this level are empty.
    message_names: []const []const u8,
};

pub const BehaviorSource = struct { name: []const u8, source: [:0]const u8 };

/// Explains the first failure in words, for the person editing the data set.
pub const Diagnostic = struct {
    text: [256]u8 = undefined,
    len: usize = 0,
    pub fn message(self: *const Diagnostic) []const u8 {
        return self.text[0..self.len];
    }
};

pub const Error = error{ InvalidDataSet, OutOfMemory };

/// Results live in `arena`; `gpa` is only used for scratch while parsing.
pub fn load(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    characters_source: [:0]const u8,
    behaviors: []const BehaviorSource,
    diagnostic: *Diagnostic,
) Error!Level {
    var loader: Loader = .{ .gpa = gpa, .arena = arena, .diagnostic = diagnostic };
    for (vocabulary.Message.fixed) |message| try loader.setMessageName(message, @tagName(message));
    var characters_tree = try Tree.parse(gpa, characters_source, "characters.zon", diagnostic);
    defer characters_tree.deinit(gpa);
    const character_root = try loader.expectStruct(characters_tree, .root, "characters.zon");
    loader.character_names = character_root.names;
    loader.characters_tree = &characters_tree;

    const loaded = try arena.alloc(vocabulary.Behavior, behaviors.len);
    for (behaviors, loaded) |source, *behavior| {
        var tree = try Tree.parse(gpa, source.source, source.name, diagnostic);
        defer tree.deinit(gpa);
        behavior.* = try loader.parseBehavior(tree, source.name);
    }
    const characters = try arena.alloc(Character, character_root.names.len);
    for (characters, 0..) |*character, index| {
        const value = character_root.vals.at(@intCast(index));
        character.* = try loader.parseCharacter(
            characters_tree,
            character_root.names[index],
            value,
            loaded,
            behaviors,
        );
    }
    return .{
        .behaviors = loaded,
        .characters = characters,
        .message_names = try loader.messageNames(),
    };
}

const Tree = struct {
    ast: std.zig.Ast,
    zoir: Zoir,

    fn parse(
        gpa: std.mem.Allocator,
        source: [:0]const u8,
        file: []const u8,
        diagnostic: *Diagnostic,
    ) Error!Tree {
        var ast = try std.zig.Ast.parse(gpa, source, .{ .mode = .zon });
        errdefer ast.deinit(gpa);
        const zoir = try std.zig.ZonGen.generate(gpa, ast, .{});
        if (ast.errors.len != 0 or zoir.hasCompileErrors()) {
            zoir.deinit(gpa);
            return fail(diagnostic, "{s}: not valid ZON", .{file});
        }
        return .{ .ast = ast, .zoir = zoir };
    }

    fn deinit(self: *Tree, gpa: std.mem.Allocator) void {
        self.zoir.deinit(gpa);
        self.ast.deinit(gpa);
    }

    fn get(self: *const Tree, index: Node.Index) Node {
        return index.get(&self.zoir);
    }

    fn name(self: *const Tree, string: Zoir.NullTerminatedString) []const u8 {
        return string.get(&self.zoir);
    }

    fn field(self: *const Tree, node: Node, wanted: []const u8) ?Node.Index {
        if (node != .struct_literal) return null;
        for (node.struct_literal.names, 0..) |candidate, i| {
            if (!std.mem.eql(u8, self.name(candidate), wanted)) continue;
            return node.struct_literal.vals.at(@intCast(i));
        }
        return null;
    }

    fn enumName(self: *const Tree, index: Node.Index) ?[]const u8 {
        return switch (self.get(index)) {
            .enum_literal => |literal| self.name(literal),
            else => null,
        };
    }

    fn int(self: *const Tree, index: Node.Index) ?i64 {
        return switch (self.get(index)) {
            .int_literal => |literal| switch (literal) {
                .small => |small| small,
                .big => |big| big.toInt(i64) catch null,
            },
            else => null,
        };
    }

    /// Elements of a list: `.{}`, `.{ a, b }`.
    fn list(self: *const Tree, index: Node.Index) ?Node.Index.Range {
        return switch (self.get(index)) {
            .array_literal => |range| range,
            .empty_literal => .{ .start = index, .len = 0 },
            else => null,
        };
    }
};

const StructNode = @FieldType(Node, "struct_literal");

const Loader = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    diagnostic: *Diagnostic,
    message_ids: std.StringArrayHashMapUnmanaged(vocabulary.Message) = .empty,
    next_message: u16 = 256,
    character_names: []const Zoir.NullTerminatedString = &.{},
    characters_tree: *const Tree = undefined,

    fn expectStruct(
        self: *Loader,
        tree: Tree,
        index: Node.Index,
        where: []const u8,
    ) Error!StructNode {
        return switch (tree.get(index)) {
            .struct_literal => |s| s,
            .empty_literal => .{ .names = &.{}, .vals = .{ .start = index, .len = 0 } },
            else => fail(self.diagnostic, "{s}: expected a struct", .{where}),
        };
    }

    fn setMessageName(self: *Loader, message: vocabulary.Message, name: []const u8) Error!void {
        try self.message_ids.put(self.arena, name, message);
    }

    fn internMessage(self: *Loader, name: []const u8) Error!vocabulary.Message {
        const entry = try self.message_ids.getOrPut(self.arena, name);
        if (!entry.found_existing) {
            entry.key_ptr.* = try self.arena.dupe(u8, name);
            entry.value_ptr.* = @fromBackingInt(self.next_message);
            self.next_message += 1;
        }
        return entry.value_ptr.*;
    }

    fn messageNames(self: *Loader) Error![]const []const u8 {
        const names = try self.arena.alloc([]const u8, self.next_message);
        @memset(names, "");
        var iterator = self.message_ids.iterator();
        while (iterator.next()) |entry| names[@backingInt(entry.value_ptr.*)] = entry.key_ptr.*;
        return names;
    }

    fn characterIndex(self: *Loader, name: []const u8) ?vocabulary.Character {
        for (self.character_names, 0..) |candidate, index| {
            if (std.mem.eql(
                u8,
                self.characters_tree.name(candidate),
                name,
            )) return @fromBackingInt(@as(u16, @intCast(index)));
        }
        return null;
    }

    fn parseBehavior(self: *Loader, tree: Tree, file: []const u8) Error!vocabulary.Behavior {
        const root = tree.get(.root);
        if (root != .struct_literal) return fail(
            self.diagnostic,
            "{s}: expected a struct",
            .{file},
        );
        const links = try self.nameList(tree, tree.field(root, "links"), file);
        const numbers = try self.nameList(tree, tree.field(root, "numbers"), file);
        const states_index = tree.field(root, "states") orelse return fail(
            self.diagnostic,
            "{s}: no states",
            .{file},
        );
        const states_node = try self.expectStruct(tree, states_index, file);
        const states = try self.arena.alloc(vocabulary.State, states_node.names.len);
        for (states, states_node.names) |*state, name| state.* = .{
            .name = try self.arena.dupe(u8, tree.name(name)),
            .animation = 0,
            .rules = &.{},
        };
        const context: Context = .{
            .tree = &tree,
            .file = file,
            .states = states,
            .links = links,
            .numbers = numbers,
        };
        for (states, 0..) |*state, index| {
            const value = tree.get(states_node.vals.at(@intCast(index)));
            const animation = tree.field(value, "animation") orelse return fail(
                self.diagnostic,
                "{s}: {s} has no animation",
                .{ file, state.name },
            );
            state.animation = std.math.cast(u16, tree.int(animation) orelse -1) orelse
                return fail(
                    self.diagnostic,
                    "{s}: {s} has an invalid animation",
                    .{ file, state.name },
                );
            const rules_index = tree.field(value, "rules") orelse return fail(
                self.diagnostic,
                "{s}: {s} has no rules",
                .{ file, state.name },
            );
            const rule_nodes = tree.list(rules_index) orelse return fail(
                self.diagnostic,
                "{s}: {s} rules must be a list",
                .{ file, state.name },
            );
            const rules = try self.arena.alloc(vocabulary.Rule, rule_nodes.len);
            for (rules, 0..) |*rule, r| rule.* = try self.parseRule(
                context,
                rule_nodes.at(@intCast(r)),
                @intCast(index),
            );
            state.rules = rules;
        }
        return .{
            .name = try self.arena.dupe(u8, std.fs.path.stem(file)),
            .links = links,
            .numbers = numbers,
            .states = states,
        };
    }

    fn nameList(
        self: *Loader,
        tree: Tree,
        index: ?Node.Index,
        file: []const u8,
    ) Error![]const []const u8 {
        const at = index orelse return &.{};
        const range = tree.list(at) orelse return fail(
            self.diagnostic,
            "{s}: links and numbers must be lists",
            .{file},
        );
        if (range.len > 4) return fail(
            self.diagnostic,
            "{s}: at most four links or numbers",
            .{file},
        );
        const names = try self.arena.alloc([]const u8, range.len);
        for (names, 0..) |*name, i| {
            const text = tree.enumName(range.at(@intCast(i))) orelse return fail(
                self.diagnostic,
                "{s}: names must be enum literals",
                .{file},
            );
            name.* = try self.arena.dupe(u8, text);
        }
        return names;
    }

    const Context = struct {
        tree: *const Tree,
        file: []const u8,
        states: []const vocabulary.State,
        links: []const []const u8,
        numbers: []const []const u8,
    };

    fn parseRule(
        self: *Loader,
        context: Context,
        index: Node.Index,
        state: u16,
    ) Error!vocabulary.Rule {
        const tree = context.tree;
        const node = tree.get(index);
        var result: vocabulary.Rule = .{ .next = state };
        if (node == .empty_literal) return result;
        const fields = try self.expectStruct(tree.*, index, context.file);
        for (fields.names, 0..) |name_string, i| {
            const name = tree.name(name_string);
            const value = fields.vals.at(@intCast(i));
            if (std.mem.eql(u8, name, "when")) {
                const range = tree.list(value) orelse return fail(
                    self.diagnostic,
                    "{s}: when must be a list",
                    .{context.file},
                );
                const checks = try self.arena.alloc(vocabulary.Operation, range.len);
                for (checks, 0..) |*check, c| {
                    check.* = try self.parseOperation(context, range.at(@intCast(c)));
                }
                result.when = checks;
            } else if (std.mem.eql(u8, name, "then")) {
                result.then = try self.parseOperation(context, value);
            } else if (std.mem.eql(u8, name, "next")) {
                const target = tree.enumName(value) orelse return fail(
                    self.diagnostic,
                    "{s}: next must name a state",
                    .{context.file},
                );
                result.next = for (context.states, 0..) |candidate, s| {
                    if (std.mem.eql(u8, candidate.name, target)) break @intCast(s);
                } else return fail(
                    self.diagnostic,
                    "{s}: unknown state {s}",
                    .{ context.file, target },
                );
            } else inline for (.{ "turn", "damage", "heal", "kill" }) |flag| {
                if (std.mem.eql(u8, name, flag)) {
                    @field(result, flag) = tree.get(value) == .true;
                    break;
                }
            } else inline for (.{ "score", "forward", "down" }) |number| {
                if (std.mem.eql(u8, name, number)) {
                    const FieldType = @FieldType(vocabulary.Rule, number);
                    @field(result, number) = std.math.cast(
                        FieldType,
                        tree.int(value) orelse return self.badNumber(context, name),
                    ) orelse
                        return self.badNumber(context, name);
                    break;
                }
            } else return fail(
                self.diagnostic,
                "{s}: unknown rule field {s}",
                .{ context.file, name },
            );
        }
        return result;
    }

    fn badNumber(self: *Loader, context: Context, name: []const u8) Error {
        return fail(self.diagnostic, "{s}: {s} must be a number in range", .{ context.file, name });
    }

    fn parseOperation(
        self: *Loader,
        context: Context,
        index: Node.Index,
    ) Error!vocabulary.Operation {
        const tree = context.tree;
        const node = tree.get(index);
        if (tree.enumName(index)) |name| {
            const info = @typeInfo(vocabulary.Operation).@"union";
            inline for (info.field_names, info.field_types) |field_name, field_type| {
                const matches = field_type == void and std.mem.eql(u8, field_name, name);
                if (matches) return @unionInit(vocabulary.Operation, field_name, {});
            }
            return fail(
                self.diagnostic,
                "{s}: unknown condition or effect {s}",
                .{ context.file, name },
            );
        }
        if (node != .struct_literal or node.struct_literal.names.len != 1) {
            return fail(
                self.diagnostic,
                "{s}: a condition or effect is a name or .{{ .name = argument }}",
                .{context.file},
            );
        }
        const name = tree.name(node.struct_literal.names[0]);
        const argument = node.struct_literal.vals.at(0);
        const info = @typeInfo(vocabulary.Operation).@"union";
        inline for (info.field_names, info.field_types) |field_name, field_type| {
            if (field_type != void and std.mem.eql(u8, field_name, name)) {
                return @unionInit(
                    vocabulary.Operation,
                    field_name,
                    try self.parseArgument(field_type, context, argument, name),
                );
            }
        }
        return fail(
            self.diagnostic,
            "{s}: unknown condition or effect {s}",
            .{ context.file, name },
        );
    }

    fn parseArgument(
        self: *Loader,
        comptime T: type,
        context: Context,
        index: Node.Index,
        operation: []const u8,
    ) Error!T {
        const tree = context.tree;
        if (T == i16) {
            return std.math.cast(i16, tree.int(index) orelse -0x10000) orelse
                fail(self.diagnostic, "{s}: {s} needs a number", .{ context.file, operation });
        }
        if (@typeInfo(T) == .@"struct") {
            var result: T = undefined;
            const node = tree.get(index);
            const info = @typeInfo(T).@"struct";
            inline for (info.field_names, info.field_types) |field_name, field_type| {
                const value = tree.field(node, field_name) orelse
                    return fail(
                        self.diagnostic,
                        "{s}: {s} needs .{s}",
                        .{ context.file, operation, field_name },
                    );
                const parsed = try self.parseArgument(field_type, context, value, operation);
                @field(result, field_name) = parsed;
            }
            return result;
        }
        const name = tree.enumName(index) orelse return fail(
            self.diagnostic,
            "{s}: {s} needs a name",
            .{ context.file, operation },
        );
        if (T == vocabulary.Message) return self.internMessage(name);
        if (T == vocabulary.Link) return slot(vocabulary.Link, context.links, name) orelse
            fail(self.diagnostic, "{s}: unknown link {s}", .{ context.file, name });
        if (T == vocabulary.Number) return slot(vocabulary.Number, context.numbers, name) orelse
            fail(self.diagnostic, "{s}: unknown number {s}", .{ context.file, name });
        if (T == vocabulary.Character) return self.characterIndex(name) orelse
            fail(self.diagnostic, "{s}: unknown character {s}", .{ context.file, name });
        if (T == vocabulary.Kind) return kind(name) orelse fail(
            self.diagnostic,
            "{s}: unknown kind {s}",
            .{ context.file, name },
        );
        return std.meta.stringToEnum(T, name) orelse fail(
            self.diagnostic,
            "{s}: {s} cannot be {s}",
            .{ context.file, operation, name },
        );
    }

    fn parseCharacter(
        self: *Loader,
        tree: Tree,
        name_string: Zoir.NullTerminatedString,
        index: Node.Index,
        behaviors: []const vocabulary.Behavior,
        sources: []const BehaviorSource,
    ) Error!Character {
        const name = try self.arena.dupe(u8, tree.name(name_string));
        const fields: Fields = .{
            .loader = self,
            .tree = &tree,
            .node = tree.get(index),
            .owner = name,
        };
        const behavior_name = try fields.name("behavior");
        const behavior_index: u16 = for (sources, 0..) |source, b| {
            if (std.mem.eql(u8, std.fs.path.stem(source.name), behavior_name)) break @intCast(b);
        } else return fail(self.diagnostic, "{s}: unknown behavior {s}", .{ name, behavior_name });
        const behavior = behaviors[behavior_index];
        const start_name = try fields.name("start");
        const kind_name = try fields.name("kind");
        const position: Fields = .{
            .loader = self,
            .tree = &tree,
            .node = tree.get(try fields.required("position")),
            .owner = name,
        };
        var result: Character = .{
            .name = name,
            .placement = try fields.integer(u16, "placement"),
            .kind = kind(kind_name) orelse return fail(
                self.diagnostic,
                "{s}: unknown kind {s}",
                .{ name, kind_name },
            ),
            .behavior = behavior_index,
            .start = behavior.stateIndex(start_name) orelse
                return fail(self.diagnostic, "{s}: unknown start state {s}", .{ name, start_name }),
            .room = try self.room(fields),
            .x = try position.integer(i16, "x"),
            .y = try position.integer(i16, "y"),
            .facing = try fields.choice(Facing, "facing"),
            .health = try fields.integer(i16, "health"),
            .width = try fields.integer(u8, "width"),
            .active = fields.flag("active"),
            .wakes_on_message = fields.flag("wakes_on_message"),
            .wakes_on_contact = fields.flag("wakes_on_contact"),
            .wakes_when_near = fields.flag("wakes_when_near"),
            .behind_player = fields.flag("behind_player"),
            .minimum_difficulty = try fields.choice(Difficulty, "minimum_difficulty"),
        };
        if (tree.field(fields.node, "label")) |label| result.label = switch (tree.get(label)) {
            .string_literal => |text| try self.arena.dupe(u8, text),
            else => return fail(self.diagnostic, "{s}: label must be a string", .{name}),
        };
        inline for (.{
            "other_flags",
            "palette_bank",
            "other_visual_flags",
            "contact_icon",
            "inventory_icon",
            "object",
            "unknown_byte_29",
        }) |field| {
            if (tree.field(fields.node, field) != null) {
                @field(result, field) = try fields.integer(u8, field);
            }
        }
        const node = fields.node;
        if (tree.field(node, "links")) |links| try self.bindLinks(&result, tree, links, behavior);
        if (tree.field(node, "numbers")) |numbers| {
            try self.bindNumbers(&result, tree, numbers, behavior);
        }
        return result;
    }

    /// A room number, or null for `.outside`.
    fn room(self: *Loader, fields: Fields) Error!?u8 {
        const value = try fields.required("room");
        const name = fields.tree.enumName(value) orelse return try fields.integer(u8, "room");
        if (!std.mem.eql(u8, name, "outside")) return fail(
            self.diagnostic,
            "{s}: room must be a number or .outside",
            .{fields.owner},
        );
        return null;
    }

    fn bindLinks(
        self: *Loader,
        character: *Character,
        tree: Tree,
        links: Node.Index,
        behavior: vocabulary.Behavior,
    ) Error!void {
        const fields = try self.expectStruct(tree, links, character.name);
        for (fields.names, 0..) |link_name, i| {
            const link = tree.name(link_name);
            const position = slot(vocabulary.Link, behavior.links, link) orelse
                return fail(
                    self.diagnostic,
                    "{s}: behavior has no link {s}",
                    .{ character.name, link },
                );
            const target = tree.enumName(fields.vals.at(@intCast(i))) orelse
                return fail(
                    self.diagnostic,
                    "{s}: link {s} must name a character",
                    .{ character.name, link },
                );
            if (std.mem.eql(u8, target, "none")) continue;
            character.links[@backingInt(position)] = self.characterIndex(target) orelse
                return fail(
                    self.diagnostic,
                    "{s}: unknown character {s}",
                    .{ character.name, target },
                );
        }
    }

    fn bindNumbers(
        self: *Loader,
        character: *Character,
        tree: Tree,
        numbers: Node.Index,
        behavior: vocabulary.Behavior,
    ) Error!void {
        const fields = try self.expectStruct(tree, numbers, character.name);
        for (fields.names, 0..) |number_name, i| {
            const number = tree.name(number_name);
            const value = std.math.cast(
                i16,
                tree.int(fields.vals.at(@intCast(i))) orelse -0x10000,
            ) orelse
                return fail(
                    self.diagnostic,
                    "{s}: number {s} out of range",
                    .{ character.name, number },
                );
            if (slot(vocabulary.Number, behavior.numbers, number)) |position| {
                character.numbers[@backingInt(position)] = value;
            } else if (unusedParameter(number)) |parameter| {
                character.unused_parameters[parameter] = value;
            } else return fail(
                self.diagnostic,
                "{s}: behavior has no number {s}",
                .{ character.name, number },
            );
        }
    }
};

/// Reads one struct's fields, naming its owner in every failure.
const Fields = struct {
    loader: *Loader,
    tree: *const Tree,
    node: Node,
    owner: []const u8,

    fn required(self: Fields, comptime field: []const u8) Error!Node.Index {
        return self.tree.field(self.node, field) orelse
            fail(self.loader.diagnostic, "{s}: missing {s}", .{ self.owner, field });
    }

    fn name(self: Fields, comptime field: []const u8) Error![]const u8 {
        return self.tree.enumName(try self.required(field)) orelse
            fail(self.loader.diagnostic, "{s}: {s} must be a name", .{ self.owner, field });
    }

    fn integer(self: Fields, comptime T: type, comptime field: []const u8) Error!T {
        const value = self.tree.int(try self.required(field)) orelse -0x1_0000_0000;
        return std.math.cast(T, value) orelse
            fail(self.loader.diagnostic, "{s}: {s} out of range", .{ self.owner, field });
    }

    fn flag(self: Fields, comptime field: []const u8) bool {
        const value = self.tree.field(self.node, field) orelse return false;
        return self.tree.get(value) == .true;
    }

    fn choice(self: Fields, comptime T: type, comptime field: []const u8) Error!T {
        const text = try self.name(field);
        return std.meta.stringToEnum(T, text) orelse
            fail(self.loader.diagnostic, "{s}: {s} cannot be {s}", .{ self.owner, field, text });
    }
};

/// `parameter_0` to `parameter_3`: a placement number no rule uses.
fn unusedParameter(name: []const u8) ?u2 {
    if (name.len != 11 or !std.mem.startsWith(u8, name, "parameter_")) return null;
    return switch (name[10]) {
        '0'...'3' => @intCast(name[10] - '0'),
        else => null,
    };
}

fn slot(comptime T: type, names: []const []const u8, name: []const u8) ?T {
    for (names, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, name)) return @fromBackingInt(@as(u2, @intCast(index)));
    }
    return null;
}

fn kind(name: []const u8) ?vocabulary.Kind {
    if (std.meta.stringToEnum(vocabulary.Kind, name)) |named| return named;
    if (!std.mem.startsWith(u8, name, "kind_")) return null;
    const value = std.fmt.parseInt(i16, name[5..], 10) catch return null;
    return @fromBackingInt(value);
}

fn fail(diagnostic: *Diagnostic, comptime format: []const u8, arguments: anytype) Error {
    const text = std.fmt.bufPrint(&diagnostic.text, format, arguments) catch diagnostic.text[0..];
    diagnostic.len = text.len;
    return error.InvalidDataSet;
}

test "a behavior and its characters load with every name resolved" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: Diagnostic = .{};
    const level = load(std.testing.allocator, arena.allocator(),
        \\.{
        \\    .conrad = .{
        \\        .placement = 0, .kind = .player, .behavior = .guest, .start = .waiting,
        \\        .room = 1, .position = .{ .x = 10, .y = 70 }, .facing = .right,
        \\        .health = 4, .width = 1, .active = true,
        \\        .minimum_difficulty = .easy },
        \\    .guest_1 = .{
        \\        .placement = 1, .label = "MAN", .kind = .interactive,
        \\        .behavior = .guest, .start = .waiting,
        \\        .room = .outside, .position = .{ .x = 32, .y = 214 }, .facing = .left,
        \\        .health = 1, .width = 1,
        \\        .active = false, .minimum_difficulty = .normal,
        \\        .links = .{ .friend = .conrad },
        \\        .numbers = .{ .room_to_appear = 19, .parameter_3 = 7 },
        \\    },
        \\}
    , &.{.{ .name = "guest.zon", .source =
        \\.{
        \\    .key = "0011", .links = .{.friend}, .numbers = .{.room_to_appear},
        \\    .states = .{
        \\        .waiting = .{ .animation = 768, .rules = .{
        \\            .{
        \\                .when = .{.{ .received = .call }},
        \\                .then = .{ .reveal = .room_to_appear },
        \\            },
        \\            .{
        \\                .when = .{ .out_of_view, .{ .chance = 5 } },
        \\                .then = .{ .send = .{ .to = .friend, .message = .hit_front_high } },
        \\                .turn = true,
        \\                .forward = -16,
        \\                .next = .fleeing,
        \\            },
        \\            .{},
        \\        } },
        \\        .fleeing = .{ .animation = 767, .rules = .{.{
        \\            .when = .{.{ .sees = .{ .kind = .player, .cells = 16 } }},
        \\            .next = .waiting,
        \\        }} },
        \\    },
        \\}
    }}, &diagnostic) catch |err| {
        std.debug.print("{s}\n", .{diagnostic.message()});
        return err;
    };
    const guest = level.behaviors[0];
    try std.testing.expectEqual(@as(usize, 2), guest.states.len);
    const flee = guest.states[0].rules[1];
    try std.testing.expectEqual(@as(u16, 1), flee.next);
    try std.testing.expect(flee.turn);
    try std.testing.expectEqual(@as(i16, -16), flee.forward);
    try std.testing.expectEqual(vocabulary.Message.hit_front_high, flee.then.?.send.message);
    try std.testing.expectEqual(@as(i16, 5), flee.when[1].chance);
    try std.testing.expectEqual(vocabulary.Kind.player, guest.states[1].rules[0].when[0].sees.kind);
    try std.testing.expectEqual(@as(u16, 0), guest.states[0].rules[2].next);
    const visitor = level.characters[1];
    try std.testing.expectEqual(@as(?u8, null), visitor.room);
    try std.testing.expectEqual(@as(?vocabulary.Character, @fromBackingInt(0)), visitor.links[0]);
    try std.testing.expectEqual(@as(i16, 19), visitor.numbers[0]);
    try std.testing.expectEqual(@as(i16, 7), visitor.unused_parameters[3]);
    try std.testing.expectEqualStrings(
        "call",
        level.message_names[@backingInt(guest.states[0].rules[0].when[0].received)],
    );
}

test "unknown names fail with a readable diagnostic" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: Diagnostic = .{};
    const guard: BehaviorSource = .{ .name = "guard.zon", .source =
        \\.{ .states = .{ .idle = .{ .animation = 1, .rules = .{.{ .when = .{.levitating} }} } } }
    };
    const result = load(std.testing.allocator, arena.allocator(), ".{}", &.{guard}, &diagnostic);
    try std.testing.expectError(error.InvalidDataSet, result);
    try std.testing.expectEqualStrings(
        "guard.zon: unknown condition or effect levitating",
        diagnostic.message(),
    );
}
