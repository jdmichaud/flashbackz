# SDL event log (`--event-log`)

The SDL host can write each device event that the game polls as one JSON object on one line. The
log goes to standard output. No code in the repository reads it, and the agent host does not
replay it.

| Item | Value |
|---|---|
| Files | The standard output of `flashbackz` or `flashbackz-standalone`. |
| Format | JSON Lines: one JSON object in ASCII on each line. Each line ends with a newline (`0x0a`). |
| Byte order | Not applicable: the log is text. |
| Reader | None in the repository. |
| Writer | `src/sdl/eventlog.zig` (`writeEvent`), called by `pollEvents` in `src/sdl/backend.zig` |

## Start the log

Give the option `--event-log SECONDS` to the SDL host, for example
`flashbackz --event-log 30 disk1.img disk2.img`.

- `SECONDS` is a decimal number more than 0 and at most 86400. It can have a fraction.
- The host stops after that time. The time starts after the first update, which starts the
  platform.
- With `--run-for` also, the host stops at the first of the two times.
- Standard output holds only the log lines. The status lines of the host go to standard error.
- The host sends the lines to the output after each game update, and at the end.
- The host ignores a write error: the log loses lines, but the game gets all its events.

## Layout

Each line is one JSON object. The fields are in this order: `kind`, `t`, then the fields of the
kind. The values are JSON strings, integers or booleans.

### Fields of all lines

| Field | Type | Content |
|---|---|---|
| `kind` | string | The kind of the event (see the next table). |
| `t` | integer, u64 | The time of the event in nanoseconds since the platform started (see [Time](#time)). |

### Kinds

| `kind` | Other fields | Content |
|---|---|---|
| `key_down` | `key`, `repeat` | A key goes down. `repeat` is `true` when the keyboard repeats a held key. |
| `key_up` | `key`, `repeat` | A key goes up. `repeat` is the repeat flag of SDL for the event. |
| `controller_added` | `controller` | SDL opens a pad as a gamepad. |
| `controller_removed` | `controller` | SDL tells that a pad is not connected now. |
| `controller_button_down` | `controller`, `button` | A pad button goes down. |
| `controller_button_up` | `controller`, `button` | A pad button goes up. |
| `controller_axis` | `controller`, `axis`, `value` | A pad axis moves to `value`, an i16 (-32768 to 32767). |
| `focus_gained` | none | The window gets the keyboard. |
| `focus_lost` | none | The window loses the keyboard. |
| `drawable_resized` | `width`, `height` | The window size changes. The values are the output size of the renderer in pixels, as u32 values. Without it, the window size of the SDL event. |
| `quit` | none | The user asks the program to stop. |

### Values

| Field | Content |
|---|---|
| `key` | The name of the key in `platform.Key` (list below). A scan code that the host does not know gives `"unknown"`. |
| `button` | The name of the button in `platform.ControllerButton`: `a`, `b`, `x`, `y`, `back`, `guide`, `start`, `left_stick`, `right_stick`, `left_shoulder`, `right_shoulder`, `dpad_up`, `dpad_down`, `dpad_left`, `dpad_right`. |
| `axis` | The name of the axis in `platform.ControllerAxis`: `left_x`, `left_y`, `right_x`, `right_y`, `trigger_left`, `trigger_right`. |
| `controller` | The joystick instance ID of SDL, as an unsigned 32-bit integer. |

The key names are `unknown`, `escape`, `enter`, `space`, `tab`, `backspace`, `left`, `right`,
`up`, `down`, `home`, `end`, `page_up`, `page_down`, `insert`, `delete`, `left_shift`,
`right_shift`, `left_ctrl`, `right_ctrl`, `left_alt`, `right_alt`, `a` to `z`, `digit_0` to
`digit_9`, `f1` to `f12`, `minus`, `equals`, `comma`, `period`, `slash`, `semicolon`,
`apostrophe`, `grave`, `left_bracket`, `right_bracket`, `backslash`, `keypad_plus` and
`keypad_minus`.

When the enum has no name for a value, the writer writes the value as an integer in place of the
name. For example, SDL buttons from 15 up have no name.

Synthetic lines:

```json
{"kind":"key_down","t":12,"key":"s","repeat":true}
{"kind":"drawable_resized","t":17,"width":640,"height":400}
{"kind":"quit","t":18}
{"kind":"controller_axis","t":20,"controller":3,"axis":"left_x","value":-300}
{"kind":"key_up","t":21,"key":9999,"repeat":false}
```

## Procedures

### Time

The host calculates `t` in these steps:

1. Take the time stamp of the SDL event, in milliseconds.
2. Change it to nanoseconds since the start of the platform.
3. If the result is later than the current time of the platform, use the current time.
4. If the result is earlier than the time of the previous event, use the time of the previous
   event.

Thus `t` never decreases from one line to the next. It has a resolution of 1 ms, except after
step 3.

### Events in the log

The host writes an event only when it changes an SDL event into a platform event. It writes the
events in the order that the game gets them.

- The host drops the key events of the window while the window does not have the keyboard. This
  is also true before the first `focus_gained`.
- SDL can send a key event of the window before its own event for the focus loss. The host then
  writes one `focus_lost` in place of that key event, and no second `focus_lost` later.
- A joystick without a gamepad mapping gets a generic mapping, and then gives
  `controller_added`.
- The host writes no line for the other SDL events.

## Checks

The writer refuses nothing. A reader must refuse a line with an integer in place of a name. It
must not read the integer as a different named value.

## Sources

- `src/sdl/eventlog.zig`.
- `src/sdl/backend.zig` (`pollEvents`, `translate`, `eventTimeNs`, `keyFromScancode`).
- `src/sdl/host.zig` (`Args`, `run`, `Options.deadlineNs`).
- `src/shared/platform.zig` (`Event`, `Key`, `ControllerButton`, `ControllerAxis`).
