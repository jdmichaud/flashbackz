//! Recover one-use credential locks and their outgoing circuits from the complete
//! family graph. Item/lock iteration order becomes explicit delivery latency.
const std = @import("std");
const runtime = @import("../key_locks.zig");
const placement = @import("placement.zig");
const rules = @import("rule_table.zig");
const animation = @import("animation.zig");
const geometry = @import("../geometry.zig");
const motion = @import("../motion.zig");
const props = @import("first_world_props.zig");
pub const QuestReceiver = struct { receiver: usize, contact: usize };
pub const Assets = struct {
    allocator: std.mem.Allocator,
    definitions: []runtime.Definition,
    clips: []animation.OwnedClip,
    bindings: []runtime.Binding,
    receivers: []runtime.Receiver,
    quest_receivers: []QuestReceiver,
    pub fn deinit(self: *Assets) void {
        for (self.definitions) |definition| {
            self.allocator.free(definition.label);
            self.allocator.free(definition.circuits);
        }
        self.allocator.free(self.definitions);
        for (self.clips) |*clip| clip.deinit();
        self.allocator.free(self.clips);
        self.allocator.free(self.bindings);
        self.allocator.free(self.receivers);
        self.allocator.free(self.quest_receivers);
    }
};
pub const Spec = struct { idle: u16, used: u16, target_parameter: u2, input: i16, output: i16, sound: ?motion.SoundId, forward: i16, down: i16, second: ?struct { parameter: u2, signal: i16 } = null, notice: ?@import("../world_messages.zig").Id = null, repaired_operation: ?struct { parameter: u2, signal: i16, sound: motion.SoundId } = null };
fn op(value: rules.Operation, code: u8, argument: i16) bool {
    return value.code == code and (code == 0 or value.argument == argument);
}
fn repairable(group: rules.Group) ?Spec {
    if (group.count() != 7) return null;
    const repair = group.at(0);
    const broken = group.at(1);
    const operate = group.at(4);
    if (repair.source == repair.target or repair.next != 4 or repair.conditions[0].code != 34 or repair.conditions[1].code != 0 or repair.effect.code < 35 or repair.effect.code > 38) return null;
    if (broken.source != repair.source or broken.target != repair.source or broken.next != 0 or !op(broken.conditions[0], 34, 30) or !op(broken.conditions[1], 90, 24) or broken.effect.code != 123 or broken.effect.argument < 0) return null;
    if (operate.source != repair.target or operate.target != repair.target or operate.next != 4 or !op(operate.conditions[0], 34, 30) or operate.conditions[1].code != 125 or operate.conditions[1].argument < 0 or operate.conditions[1].argument >= 66 or operate.effect.code < 35 or operate.effect.code > 38) return null;
    for (0..7) |i| {
        const r = group.at(i);
        if (r.flags != 0 or (i != 0 and (r.dx != 0 or r.dy != 0))) return null;
    }
    for ([_]usize{ 2, 3, 5, 6 }) |i| {
        const r = group.at(i);
        const next: u16 = if (i < 4) 0 else 4;
        const state = if (i < 4) repair.source else repair.target;
        const sleep = i == 2 or i == 5;
        if (r.source != state or r.target != state or r.next != next or !op(r.conditions[0], if (sleep) 77 else 0, 0) or r.conditions[1].code != 0 or !op(r.effect, if (sleep) 67 else 0, 0)) return null;
    }
    return .{ .idle = repair.source, .used = repair.target, .target_parameter = @intCast(repair.effect.code - 35), .input = repair.conditions[0].argument, .output = repair.effect.argument, .sound = null, .forward = -@as(i16, repair.dx), .down = repair.dy, .notice = @fromBackingInt(@as(u16, @intCast(broken.effect.argument))), .repaired_operation = .{ .parameter = @intCast(operate.effect.code - 35), .signal = operate.effect.argument, .sound = @fromBackingInt(@as(u8, @intCast(operate.conditions[1].argument))) } };
}
pub fn recognize(group: rules.Group) ?Spec {
    if (repairable(group)) |spec| return spec;
    const instructed = group.count() == 6;
    if (group.count() != 5 and !instructed) return null;
    const begin: usize = if (instructed) 1 else 0;
    const use = group.at(begin);
    if (use.source == use.target or use.flags != 0 or use.next != begin + 3 or use.conditions[0].code != 34 or use.conditions[1].code < 35 or use.conditions[1].code > 38) return null;
    if (instructed) {
        const hint = group.at(0);
        if (hint.source != use.source or hint.target != use.source or hint.next != 0 or hint.dx != 0 or hint.dy != 0 or hint.flags != 0 or !op(hint.conditions[0], 34, 30) or hint.conditions[1].code != 0 or hint.effect.code != 123 or hint.effect.argument < 0 or use.effect.code < 35 or use.effect.code > 38) return null;
    } else if (use.effect.code != 125 or use.effect.argument < 0 or use.effect.argument >= 66) return null;
    for (1..5) |i| {
        const r = group.at(begin + i);
        const used = i >= 3;
        const sleeping = i == 1 or i == 3;
        const state = if (used) use.target else use.source;
        if (r.source != state or r.target != state or r.next != (if (used) @as(u16, @intCast(begin + 3)) else 0) or r.dx != 0 or r.dy != 0 or r.flags != 0) return null;
        if (!op(r.conditions[0], if (sleeping) 77 else 0, 0) or !op(r.conditions[1], 0, 0) or !op(r.effect, if (sleeping) 67 else 0, 0)) return null;
    }
    return .{ .idle = use.source, .used = use.target, .target_parameter = @intCast(use.conditions[1].code - 35), .input = use.conditions[0].argument, .output = use.conditions[1].argument, .sound = if (instructed) null else @as(motion.SoundId, @fromBackingInt(@as(u8, @intCast(use.effect.argument)))), .forward = -@as(i16, use.dx), .down = use.dy, .second = if (instructed) .{ .parameter = @intCast(use.effect.code - 35), .signal = use.effect.argument } else null, .notice = if (instructed) @fromBackingInt(@as(u16, @intCast(group.at(0).effect.argument))) else null };
}
pub fn load(allocator: std.mem.Allocator, table: placement.Table, rule_bytes: []const u8, animations: []const u8, names: []const u8, room_ids: *const [64]geometry.RoomId, difficulty: @import("../settings.zig").Difficulty, connections: *std.ArrayList(props.Connection), item_sources: []const u16, quest_contacts: @import("quest_contacts.zig").Assets, first_item: @import("../equipment.zig").ItemHandle, resolver: anytype) !Assets {
    var definitions: std.ArrayList(runtime.Definition) = .empty;
    errdefer {
        for (definitions.items) |definition| {
            allocator.free(definition.label);
            allocator.free(definition.circuits);
        }
        definitions.deinit(allocator);
    }
    var clips: std.ArrayList(animation.OwnedClip) = .empty;
    errdefer {
        for (clips.items) |*clip| clip.deinit();
        clips.deinit(allocator);
    }
    var sources: std.ArrayList(u16) = .empty;
    defer sources.deinit(allocator);
    var quest_receivers: std.ArrayList(QuestReceiver) = .empty;
    errdefer quest_receivers.deinit(allocator);
    var receivers: std.ArrayList(runtime.Receiver) = .empty;
    errdefer receivers.deinit(allocator);
    var bindings: std.ArrayList(runtime.Binding) = .empty;
    errdefer bindings.deinit(allocator);
    for (0..table.count) |i| {
        const record = try table.record(@intCast(i));
        if (record.kind != 5 or record.minimum_difficulty > @backingInt(difficulty)) continue;
        const spec = recognize(try rules.group(rule_bytes, record.rule_group)) orelse continue;
        if (record.initial_state != spec.idle and record.initial_state != spec.used) return error.UnsupportedLockStart;
        if (record.room >= room_ids.len or record.contact_icon == 0) return error.InvalidLockPlacement;
        const target = record.parameters[spec.target_parameter];
        if (target < 0 or target >= table.count) return error.InvalidLockConnection;
        const circuits = try allocator.alloc(@import("../world_props.zig").CircuitId, if (spec.second != null) 2 else 1);
        errdefer allocator.free(circuits);
        circuits[0] = try props.internConnection(allocator, connections, @intCast(i), @intCast(target), spec.output);
        if (spec.second) |output| {
            const other = record.parameters[output.parameter];
            if (other < 0 or other >= table.count) return error.InvalidLockConnection;
            circuits[1] = try props.internConnection(allocator, connections, @intCast(i), @intCast(other), output.signal);
        }
        const repaired_operation: @FieldType(runtime.Definition, "repaired_operation") = if (spec.repaired_operation) |operation| result: {
            const destination = record.parameters[operation.parameter];
            if (destination < 0 or destination >= table.count) return error.InvalidRepairedControlConnection;
            break :result .{ .circuit = try props.internConnection(allocator, connections, @intCast(i), @intCast(destination), operation.signal), .sound = operation.sound };
        } else null;
        var pair: [2]motion.Clip = undefined;
        for ([_]u16{ spec.idle, spec.used }, &pair) |state, *destination| {
            var source = try animation.decode(allocator, animations, state);
            defer source.deinit();
            for (source.frames) |frame| switch (frame) {
                .hold => {},
                .frame => |f| if (f.dx != 0 or f.dy != 0) return error.MovingLockAnimation,
            };
            var clip = try source.resolve(allocator, resolver);
            errdefer clip.deinit();
            try clips.append(allocator, clip);
            destination.* = clip.clip();
        }
        try sources.append(allocator, @intCast(i));
        const label = try @import("string_table.zig").copy(allocator, names, record.text_id);
        errdefer allocator.free(label);
        table.register(@intCast(i), .key_locks);
        try definitions.append(allocator, .{ .footprint = .{ .room = room_ids[record.room], .position = record.position, .width = record.collision_width }, .facing = if (record.facing_right == 0) .left else .right, .palette_bank = @intCast(record.visual_flags & 3), .layer = if (record.visual_flags & 8 != 0) .behind_player else .in_front_of_player, .idle = pair[0], .used = pair[1], .credential = record.life, .interaction_priority = @intCast(i), .unlock_forward = spec.forward, .unlock_down = spec.down, .unlock_sound = spec.sound, .circuits = circuits, .repaired_operation = repaired_operation, .notice = spec.notice, .initially_used = record.initial_state == spec.used, .initially_active = record.initially_active != 0, .wake_when_near = record.flags & 4 != 0, .accepts_signals = record.flags & 1 != 0, .hint = try resolver.icon(record.contact_icon - 1), .label = label });
    }
    // Preserve contact selection across all implemented controls, including controls
    // whose normal operation ignores an item's credential signal.
    for (0..table.count) |i| {
        const record = try table.record(@intCast(i));
        if (record.kind != 5 or record.minimum_difficulty > @backingInt(difficulty)) continue;
        const quest_index = std.mem.indexOfScalar(u16, quest_contacts.sources, @intCast(i));
        if (quest_index == null and record.room >= room_ids.len) continue;
        const footprint: @import("../contacts.zig").Footprint = if (quest_index) |index| quest_contacts.definitions[index].footprint else .{ .room = room_ids[record.room], .position = record.position, .width = record.collision_width };
        const group = try rules.group(rule_bytes, record.rule_group);
        const lock = std.mem.indexOfScalar(u16, sources.items, @intCast(i));
        const manual = @import("operated_controls.zig").recognize(group);
        const service = @import("service_counters.zig").recognize(group);
        const mission = @import("mission_terminals.zig").recognize(group);
        const quest = @import("quest_contacts.zig").recognize(group);
        const terminal = @import("credential_terminals.zig").recognize(group);
        const external_signal: ?i16 = if (service) |value| value.signal else if (mission) |value| value.signals[1] else if (quest) |value| value.receive else if (terminal) |value| value.signal else null;
        if (lock == null and external_signal == null and quest_index == null and (manual == null or record.initial_state != manual.?.idle)) continue;
        const receiver = receivers.items.len;
        if (quest_index) |index| try quest_receivers.append(allocator, .{ .receiver = receiver, .contact = index });
        try receivers.append(allocator, .{ .footprint = footprint, .credential = record.life, .target = if (lock) |index| .{ .lock = index } else if (external_signal != null) .signal_only else .ignores_credential });
        for (item_sources, 0..) |source, index| {
            const item = try table.record(source);
            if (item.parameters[0] != record.kind) continue;
            const item_rules = try rules.group(rule_bytes, item.rule_group);
            const signal = if (@import("key_pickups.zig").recognize(item_rules)) |key| key.signal else if (@import("cartridges.zig").recognize(item_rules)) |cartridge| cartridge.signal else if (@import("quest_items.zig").card(item_rules)) |card| card.signal else if (@import("credential_cards.zig").starting(item_rules)) |card| card.signal else if (@import("credential_cards.zig").permit(item_rules)) |card| card.signal else if (@import("credential_cards.zig").parcel(item_rules)) |parcel| parcel.signal else if (@import("credential_cards.zig").papers(item_rules)) |papers| papers.signal else if (@import("credential_cards.zig").terminal(item_rules)) |card| card.signal else continue;
            if (lock == null and signal == 30) return error.UnsupportedItemOperatedControl;
            const circuit = if (external_signal != null and signal == external_signal.?) try props.internConnection(allocator, connections, source, @intCast(i), signal) else null;
            try bindings.append(allocator, .{ .circuit = circuit, .item = .{ .index = first_item.index + @as(u16, @intCast(index)), .generation = first_item.generation }, .receiver = receiver, .activates = if (lock != null) signal == recognize(group).?.input else false, .next_step = source >= i });
        }
    }
    const owned = try definitions.toOwnedSlice(allocator);
    errdefer {
        for (owned) |definition| {
            allocator.free(definition.label);
            allocator.free(definition.circuits);
        }
        allocator.free(owned);
    }
    const owned_clips = try clips.toOwnedSlice(allocator);
    errdefer {
        for (owned_clips) |*clip| clip.deinit();
        allocator.free(owned_clips);
    }
    const owned_receivers = try receivers.toOwnedSlice(allocator);
    errdefer allocator.free(owned_receivers);
    const owned_quests = try quest_receivers.toOwnedSlice(allocator);
    errdefer allocator.free(owned_quests);
    return .{ .allocator = allocator, .definitions = owned, .clips = owned_clips, .receivers = owned_receivers, .quest_receivers = owned_quests, .bindings = try bindings.toOwnedSlice(allocator) };
}
