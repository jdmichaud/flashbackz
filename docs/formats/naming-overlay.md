# Naming overlay (`src/extract/names.zon`)

The naming overlay gives our names to the behaviors, states, links, numbers and messages that the
extractor writes. It finds a behavior by a structural key: a digest of the original rule group.
The repository holds the overlay; it holds no original content.

| Item | Value |
| --- | --- |
| Files | `src/extract/names.zon` (built into the extractor); the file that `--names FILE` gives |
| Format | ASCII text in ZON. Byte order does not apply. |
| Reader | `src/extract/names.zig` (`parse`, `Overlay.behavior`, `Overlay.message`) |
| Key | `src/extract/key.zig` (`compute`) |
| Writer | People, with a text editor |
| Applied by | `src/extract/level.zig` (`nameBehaviors`, `classifyParameters`, `messageName`, `characterId`) |

## Layout

The root is a struct literal. The reader uses `std.zon.parse`: it refuses an unknown field, and
each field with no default value must be present. The file of `--names` must be smaller than
1 MiB.

| Field | Type | If absent | Content |
| --- | --- | --- | --- |
| `behaviors` | List of behavior entries | Empty | The names of behaviors |
| `messages` | List of message entries | Empty | The names of message values |

### Behavior entry

| Field | Type | If absent | Content |
| --- | --- | --- | --- |
| `key` | String | Necessary | The structural key of the rule group: 16 lowercase hexadecimal digits |
| `name` | String | Necessary | The behavior name. It is also the base of the character names. |
| `states` | List of `.{ .ordinal = u16, .name = string }` | Empty | The state names, by ordinal |
| `links` | List of `.{ .parameter = 0 to 3, .name = string }` | Empty | The link names, by placement parameter |
| `numbers` | List of `.{ .parameter = 0 to 3, .name = string }` | Empty | The number names, by placement parameter |

The ordinal of a state is its order of first appearance in the rules of the group. The source of
a rule comes before its target. Each generated behavior file shows it after the state name,
as `// ordinal N`. A state with no rules that the extractor adds for a placement
([behaviors.md](behaviors.md)) gets the next ordinal after the others.

### Message entry

| Field | Type | If absent | Content |
| --- | --- | --- | --- |
| `level` | String | Necessary | A level directory name (`city`), or `all` for all levels |
| `value` | `i16` | Necessary | The original message value |
| `name` | String | Necessary | The message name |

### Example

This example is synthetic.

```zon
// Our names for extracted behaviors, their states, links and numbers, and messages.
.{
    .behaviors = .{
        .{
            .key = "0123456789abcdef",
            .name = "guard",
            .states = .{
                .{ .ordinal = 0, .name = "waiting" },
                .{ .ordinal = 1, .name = "aiming" },
            },
            .links = .{.{ .parameter = 0, .name = "friend" }},
            .numbers = .{.{ .parameter = 2, .name = "room_to_appear" }},
        },
    },
    .messages = .{
        .{ .level = "all", .value = 20, .name = "call" },
        .{ .level = "city", .value = 20, .name = "alarm" },
    },
}
```

### The structural key

The key is the same for two copies of one behavior that use other animations or other message
values. The `hit` message of `facing_target_unhittable` and `backturned_target_unhittable` is an
exception: the key keeps its value. The key differs when anything else in the rules differs.
The extractor computes it from all records of the rule group, the unreachable ones included
([rule-groups.md](rule-groups.md)).

For each rule record, in file order, the extractor makes an encoded record of 18 bytes. All
values are little-endian. An argument is the `i16` of the original record, read as a `u16`.

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 2 | `u16` | The renumbered source state |
| 2 | 2 | `u16` | The renumbered target state |
| 4 | 1 | `i8` | dx, as in the original record |
| 5 | 1 | `i8` | dy, as in the original record |
| 6 | 1 | `u8` | The flags, as in the original record |
| 7 | 2 | `u16` | The `next` field (record offset 10), as in the original record |
| 9 | 1 | `u8` | The code of the first condition (record offset 7) |
| 10 | 2 | `u16` | The argument of the first condition (record offset 12), renumbered for a message operation |
| 12 | 1 | `u8` | The code of the second condition (record offset 6) |
| 13 | 2 | `u16` | The argument of the second condition (record offset 14), renumbered for a message operation |
| 15 | 1 | `u8` | The code of the effect (record offset 9) |
| 16 | 2 | `u16` | The argument of the effect (record offset 16), renumbered for a message operation |

The message operations are the codes whose vocabulary name is `received`, `send`,
`send_to_touching_object`, `send_to_selected_item`, `send_to_touching_facing_opposite`,
`send_to_touching_facing_same`, `send_to_matching_device`, `acknowledge`,
`send_to_touching_device`, `broadcast`, `appear_at_sender`, `offer_payment`, `board_sender` or
`release_on`. The extractor does not renumber the arguments of other codes, or of unknown codes.

## Procedures

### How to compute a key

1. Start two empty renumber tables: one for states, one for messages.
2. Take the next rule record, in file order. Renumber its source state, then its target state,
   in the state table.
3. Renumber the argument of each message operation in the message table. The order is the first
   condition, the second condition, the effect.
4. Write the encoded record of 18 bytes. Then go back to step 2 until no rule record is left.
5. Compute the SHA-256 digest of all encoded records, one after the other.
6. The key is the first 8 bytes of the digest, as 16 lowercase hexadecimal digits.

A renumber table gives a value its index of first appearance: 0, 1, 2 and so on. A value that
the table already holds gets the same index again. A table holds at most 512 values. A new value
after that gets 0xffff.

### How the extractor applies the overlay

1. It reads and checks the overlay. Then, for each level, it collects the rule groups that the
   placements use.
2. For each group, it computes the key and finds the first behavior entry with that key.
3. The behavior name is the name of the entry, or `behavior_G` with G the group number. The
   file name is the behavior name. When two or more groups of a level get the same name, each
   file name gets `_G` after the name.
4. Each state gets `state_N`, with N its animation number. A state entry with its ordinal
   replaces that name.
5. A parameter (0 to 3) is a link when the reachable rules use it as a link. It is also a link
   when the entry names it as a link. Its name is the name of the entry, or `link_P`.
6. Each parameter that the reachable rules use as a number is a number. Its name is the name of
   the entry, or the default name of the operation ([behaviors.md](behaviors.md)), or
   `number_P`. A parameter that the rules do not use as a number is also a number when the entry
   names it.
7. For a message value, a message entry of the level wins over an entry for `all`. With no entry,
   the extractor uses the engine name of the value (`hit_behind_high` to `hit_front_low`,
   `acknowledged`). Else it uses `signal_N` or `signal_minus_N`.
8. A character gets the behavior name as the base of its name when the overlay names the behavior
   ([characters.md](characters.md)).

The report gives how many behaviors and states the overlay names ([data-set.md](data-set.md)).

## Rules for the overlay

- Each name must be ours. It tells what the thing does or is, for example
  `frightened_civilian`, `watching` or `appear_in_room`.
- The overlay must contain no original content: no texts, labels, bytes or other data of the
  game. It holds only names, keys, ordinals, parameter positions, level names and message values.
- Each name must be a plain identifier: letters, digits and `_`, no digit first, and not a Zig
  keyword or primitive type name.
- Take the key from the `.key` field of a generated behavior file, and the ordinals from its
  `// ordinal N` comments.
- The state names of one behavior must differ from each other and from its `state_N` names.
- A message entry must not have the value 1, 2, 3, 4 or 12. The engine knows these messages only
  by their engine names (`hit_behind_high` to `hit_front_low`, `acknowledged`), and an entry
  replaces that name.
- A change to the encoded record of the key changes all keys. Then each entry must get its new
  key.

## Checks

| Check | Error |
| --- | --- |
| The overlay is not valid ZON or does not match its types, for example an unknown field or a value out of range | `ParseZon`; the extractor logs the ZON diagnostic with `naming overlay` |
| A name is not a plain identifier | `InvalidOverlayName` |
| Two states of one behavior get the same name | `DuplicateStateName` |

With `--extract`, the game prints `PROGRAM: extraction failed: ERROR` and stops. With the
extraction in memory, the game logs `data set not extracted: ERROR` and runs with no data set
([data-set.md](data-set.md)).

## Sources

- `src/extract/names.zig`: the types, `parse`, `Overlay.behavior`, `Overlay.message`.
- `src/extract/key.zig`: `compute`, `Renumbering`, `carriesMessage`.
- `src/extract/rule_table.zig`: the rule record.
- `src/extract/codes.zig`: the argument forms of the codes, `engineMessage`.
- `src/extract/level.zig`: `collectBehavior`, `nameBehaviors`, `classifyParameters`,
  `messageName`, `characterId`.
- `src/extract/zon.zig`: `isPlainIdentifier`.
- `src/native/cli.zig`: `--names`.
