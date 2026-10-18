# Animations (`LEVELn.ANI`)

An animation file holds the animations of the characters of one level. Each state of a behavior
shows the animation with the number of the state: a list of frames, each with a sprite and a
movement. The engine reads the file in place, also past the last frame of an animation.

| Item | Value |
| --- | --- |
| Files | `DATA/LEVEL1.ANI`, `LEVEL2.ANI`, `LEVEL3.ANI`, `LEVEL4_1.ANI`, `LEVEL4_2.ANI`, `LEVEL5_1.ANI` and `LEVEL5_2.ANI`: one file for each level. |
| Byte order | Little-endian. |
| Reader | `Animations` in `src/shared/content/animations.zig`, called by `level_pack.load`. The engine (`src/shared/behavior/world.zig`) and `character_art.load` read the frames. |
| Writer | None: the files come from the original game. |

## Layout

### Directory

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 2 | `u16` | `count`: the number of entries in the directory. |
| 2 | 2 × `count` | `u16[count]` | The offset of each animation, from byte 2 of the file. |

Animation `n` starts at file offset `2 + entry[n]`. Two or more entries can give the same offset.
In the original files, the animations follow the directory and each other with no gap. Some
entries give the end of the file, and no state uses them.

### Animation

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 2 | `u16` | The frame count. |
| 2 | 1 | `u8` | The entry sound plus 1. The value 0 tells that there is no sound. |
| 3 | 1 | `u8` | The pose tag. |
| 4 | 2 | `u16` | The art kind: 0 for a character sprite, another value for composed object art. |
| 6 | 4 × frames | frame records | The frames. |

### Frame

| Offset | Size | Type | Content |
| --- | --- | --- | --- |
| 0 | 2 | `u16` | The sprite. The value 0xffff tells that the frame has no sprite. Else bits 0 to 14 give the sprite number, and bit 15 (0x8000) mirrors the sprite. |
| 2 | 1 | `i8` | `dx`: the movement toward the back of the character, in pixels. |
| 3 | 1 | `i8` | `dy`: the movement down, in pixels. |

### The fields

- **State numbers.** The number of a state is the index of its animation in the directory. The
  rule groups ([rule-groups.md](rule-groups.md)) and the placements
  ([placements.md](placements.md)) use these numbers.
- **Entry sound.** When a rule moves a character into a state, the engine requests sound `byte - 1`
  of the sound effects ([sound-effects.md](sound-effects.md)). The engine plays it only for an awake
  character in the view room or in a room next to it. The effect `sleep_unless_near_player` (code
  67) cancels the sound. An awake character runs in each update. An asleep character does not run
  until an event wakes it, as its flags allow
  ([characters.md](characters.md#how-a-character-wakes-during-play)). The view room is the room on
  the screen, the room of Conrad.
- **Pose tag.** `touching_kind_in_pose` (code 60) and `touching_in_pose` (code 61) compare the
  low byte of their argument with this byte.
- **Art kind.** For 0, the sprite number selects a character sprite ([sprites.md](sprites.md)).
  For another value, it selects composed object art ([object-art.md](object-art.md)).
- **Sprite.** The art faces left. When the engine plays a frame, it mirrors the sprite if bit 15
  is 1 or if the character faces right, but not both.
- **No sprite.** A frame with the sprite 0xffff does not move the character, and the character
  keeps its last sprite.
- **Movement.** For a character that faces left, the engine adds `dx` to `x`. For a character
  that faces right, it subtracts `dx` as a 16-bit value: a `dx` of -128 adds 128. It always adds
  `dy` to `y`.

## Procedures

### Read the file

1. Read the file. It must have at most 1048576 bytes.
2. Read `count`. Make sure that the directory (`2 + 2 * count` bytes) is in the file.
3. Keep the file in memory. The engine reads the animations from it in place.

### Get animation `n`

1. Make sure that `n` is less than `count`.
2. Read entry `n`. The animation starts at offset `2 + entry[n]`.
3. Make sure that the 6 bytes of the header are in the file.
4. Make sure that the frame count is not 0, and that all the frames are in the file.
5. Frame `k` is at offset `2 + entry[n] + 6 + 4 * k`.

### Play an animation

1. When a rule fires, the engine sets the cursor of the character to 0. It plays frame 0 in the same
   update. A rule fires when its conditions hold: its effect runs, and the character goes into the
   next state of the rule ([rule-groups.md](rule-groups.md)). The cursor is the index of the next
   frame of the animation.
2. In each next update, if the frame count is more than the cursor, the engine plays the frame at
   the cursor. Then it adds 1 to the cursor.
3. If no frames remain, the engine tries the rules of the state. If no rule fires, the character
   keeps its last frame.

Thus an animation of `N` frames takes `N` updates.

A message is a signal that a character sends to a character: a number in the original, a name in the
data set. A message that a rule of the state waits for stops the animation before its end. The
engine then adds the movement of each remaining frame with a sprite, and tries the rules in the same
update.

## Checks

The reader checks the directory when it reads the file, and an animation when the code gets it.

| Condition | Error |
| --- | --- |
| The file has more than 1048576 bytes. | `error.TooLarge` |
| The file has fewer than 2 bytes, or the directory is not complete. | `error.TruncatedAnimationDirectory` |
| The number `n` is not less than `count`. | `error.MissingAnimation` |
| The 6 bytes of the header are not in the file. | `error.InvalidAnimationOffset` |
| The frame count is 0, or the frames go past the end of the file. | `error.InvalidAnimationLength` |

When a level loads, the game gets the animation of each state of the data set. An error stops the
load. `character_art.load` skips the other animations that give an error. Thus only the
animations that a state uses must be valid. In the original files, the entries that give the end
of the file are not valid.

## Quirks

- **The frame after the last frame.** The engine shows a frame without its movement at the start
  of the level, and after `reveal` and `transport`. If the cursor is less than the low byte of
  the frame count, the engine sets the cursor to 0 and shows frame 0. Else it reads the frame at
  the cursor, after the last frame. In the original files, these 4 bytes are the start of the
  header of the next animation. Past the end of the file, the engine uses a frame with no sprite.
  A new file must keep the same bytes after each animation, to show the same frames as the
  original. Such a frame can name a sprite that the level does not decode, and that sprite draws
  nothing. Play with the original files never shows this frame: the trace sessions of the seven
  levels and the three demos show none.
- **The mirror of a shown frame.** When the engine shows a frame without its movement, it ignores
  bit 15 of the sprite. It mirrors the sprite only if the character faces right.
- **A signed frame count.** In play, and when a message stops an animation, the engine compares
  the low byte of the frame count with the cursor as `i8`. Thus a count from 128 to 257 plays only
  frame 0. The frame count must be from 1 to 127. In the original files, the largest count is 93.

## Sources

- `src/shared/content/animations.zig`, `src/shared/content/level_pack.zig` and
  `src/shared/content/character_art.zig`.
- `src/shared/behavior/world.zig` (`updateCharacter`, `playFrame`, `showFrame`,
  `skipToAwaitedRule` and `requestSound`), `src/shared/behavior/operations/contact.zig` (the
  pose tag) and `src/shared/scenes/level.zig` (`checkContent`).
- flashback-re: `docs/animation-port-map.md`, `docs/rules/engine-update.md` (section 3) and
  `docs/rules/engine-level.md` (section 1.7).
