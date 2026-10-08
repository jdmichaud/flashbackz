//! Preserve authored placement order while discarding source identifiers from runtime tasks.
const std = @import("std");
const Task = @import("../character_schedule.zig").Task;
const Entry = struct { source: u16, task: Task };
pub fn build(allocator: std.mem.Allocator, owners: anytype, player_shot: u16) ![]Task {
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(allocator);
    inline for (.{ .{ "gunmen", .gunman }, .{ "guards", .guard }, .{ "quest_contacts", .quest_contact }, .{ "rescue_contacts", .rescue_contact }, .{ "attentive_contacts", .host }, .{ "service_counters", .service_counter } }) |family| {
        for (@field(owners, family[0]).sources, 0..) |source, index| try entries.append(allocator, .{ .source = source, .task = @unionInit(Task, @tagName(family[1]), index) });
    }
    try entries.append(allocator, .{ .source = player_shot, .task = .player_shot });
    std.mem.sort(Entry, entries.items, {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            return a.source < b.source;
        }
    }.less);
    const tasks = try allocator.alloc(Task, entries.items.len);
    errdefer allocator.free(tasks);
    for (entries.items, tasks, 0..) |entry, *task, index| {
        if (index != 0 and entries.items[index - 1].source == entry.source) return error.DuplicateCharacterOwner;
        task.* = entry.task;
    }
    return tasks;
}
