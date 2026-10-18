# Settings (`settings.zon`)

The settings record holds the options of the player and the pad layouts as one ZON record. The
game reads it at start and writes it after a setting changes. A pad model is a model of gamepad,
which SDL identifies by a GUID. A pad layout gives the button of each action for one pad model.

| Item | Value |
|---|---|
| Files | `settings.zon` |
| Place | The configuration directory (see [Configuration directory](#configuration-directory)). |
| Format | ZON text in ASCII, with a newline (`0x0a`) at the end. At most 4096 bytes. |
| Byte order | Not applicable: the record is text. |
| Reader | `src/shared/settings.zig` (`load`, `decode`), called by `Game.initWithEntry` in `src/shared/game.zig` |
| Writer | `src/shared/settings.zig` (`save`, `encode`), called by `Game.keepSettings` in `src/shared/game.zig` |

## Configuration directory

The host finds the configuration directory in this order:

1. The `--config DIR` option gives the directory.
2. On Windows, the directory is `%APPDATA%\flashbackz`.
3. On other systems, the directory is `$XDG_CONFIG_HOME/flashbackz` when `XDG_CONFIG_HOME` is set
   and not empty. Else it is `$HOME/.config/flashbackz`.
4. The host creates the directory if necessary.

The end of `flashbackz --help` gives the directory of steps 2 and 3 for the current environment.
The saves are in another directory ([save.md](save.md#storage)), which also gives the name rules
and the procedure that replaces a record. An old `SETTINGS` record in the save directory has no
effect.

## Layout

The record uses the ZON notation of [save.md](save.md#zon-notation). All the fields must be
present, and the reader refuses an unknown field. The Default column gives the value that the
game uses when it has no valid record.

### Record

| Field | Type | Range | Default | Content |
|---|---|---|---|---|
| `version` | u32 | 2 | 2 | The format version. |
| `volume` | u8 | 0 to 100 | 100 | The master volume in percent: a gain on the full sound mix. |
| `sound_fx` | bool | | `true` | The sound effects play. |
| `music` | bool | | `true` | The music plays. |
| `joystick` | bool | | `false` | The Joystick option: the pads move Conrad. |
| `zoom` | enum | `off`, `on`, `auto` | `off` | The zoom view. A level that starts takes only `auto` from it. |
| `pads` | list of Pad | 0 to 8 items | `.{}` | The pad models with a layout that is not the fixed layout. |

### Pad

| Field | Type | Fixed layout | Content |
|---|---|---|---|
| `model` | string, 32 bytes | | The GUID of the pad model as SDL gives it in text. All pads of one model have the same GUID. |
| `act` | Button | `a` | The button for the ACT action. |
| `gun` | Button | `b` | The button for the GUN action. |
| `use` | Button | `x` | The button for the USE action. |
| `inventory` | Button | `y` | The button for the INVENTORY action. |
| `pause` | Button | `start` | The button for the PAUSE action. |

A Button is one of these enum values, in the order of SDL: `a`, `b`, `x`, `y`, `back`, `guide`,
`start`, `left_stick`, `right_stick`, `left_shoulder`, `right_shoulder`, `dpad_up`, `dpad_down`,
`dpad_left`, `dpad_right`.

A synthetic record with one pad model:

```zon
.{
    .version = 2,
    .volume = 40,
    .sound_fx = false,
    .music = true,
    .joystick = true,
    .zoom = .auto,
    .pads = .{.{
        .model = "00000000000000000000000000000001",
        .act = .left_shoulder,
        .gun = .b,
        .use = .x,
        .inventory = .y,
        .pause = .start,
    }},
}
```

## Procedures

### Read

The game reads the record once, when it starts:

1. Without storage, use the defaults.
2. Read the record `settings.zon`. If the read fails (for example, the record is missing), use the
   defaults.
3. If the record has more than 4096 bytes, use the defaults.
4. Parse the ZON text. If the parse fails, use the defaults.
5. If `version` is not 2, `volume` is more than 100, or `pads` has more than 8 items, use the
   defaults.
6. If a `model` does not have exactly 32 bytes, or occurs a second time in `pads`, use the
   defaults.
7. If a pad gives one button to two actions, or gives a D-pad button to an action, use the
   defaults.
8. Else use the values of the record.

The reader never keeps a part of a record: a refused record gives all the defaults. It does not
write the defaults back. The record stays as it is until a setting changes.

### Write

1. Compare the settings with the settings that the storage keeps. Do this at the start of each
   host frame and when the game stops.
2. If they are the same, stop.
3. Write all the fields in the order of the Record table, then a newline.
4. In `pads`, write only the models that do not have the fixed layout, in the order of the list.
5. If the write succeeds, keep the settings as the settings of the storage. If it fails, step 1
   tries again at the next host frame.

Without storage, the game writes nothing. The agent host without `--config` keeps the record in
memory, and the record does not stay after the run.

### Pad list

- A pad model that gets the fixed layout goes out of the list.
- A changed model goes to the end of the list.
- When a ninth model gets a layout, the first model of the list goes out.
- The CONTROLS page gives an action only a button that is not a D-pad button. When an action gets
  the button of another action, the two actions exchange their buttons.

## Checks

| Condition | Result |
|---|---|
| The record is missing or does not read from the storage. | The defaults. |
| The record has more than 4096 bytes. | The defaults. |
| The text is not valid ZON, a field is missing or unknown, or a value has a wrong type or range. | The defaults. |
| `version` is not 2. | The defaults. |
| `volume` is more than 100. | The defaults. |
| `pads` has more than 8 items. | The defaults. |
| A `model` does not have exactly 32 bytes. | The defaults. |
| A `model` occurs two times in `pads`. | The defaults. |
| Two actions of a pad have the same button. | The defaults. |
| An action of a pad has a D-pad button (`dpad_up`, `dpad_down`, `dpad_left` or `dpad_right`). | The defaults. |

The writer never writes these pads (see [Pad list](#pad-list)).

The reader refuses a record of another version. It does not convert it.

## Sources

- `src/shared/settings.zig`.
- `src/shared/game.zig` (`initWithEntry`, `keepSettings`, `padEvent`, `globalKey`).
- `src/shared/scenes/game_options.zig`, `src/shared/scenes/level.zig` (the zoom at the start of a
  level).
- flashback-re: `docs/game-options.md`, and `docs/rules/engine-presentation.md` 4.3 (the zoom
  view).
