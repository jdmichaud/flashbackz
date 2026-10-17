# Agent host output (`flashbackz-agent`)

The agent host runs the game without a window, for a number of host frames, with scripted input
and a clock at 60 Hz. At the end, it writes two JSON lines on standard output. With `--trace`, it
also writes JSON lines on standard error during the run. Two runs with the same arguments and
the same files give the same lines.

| Item | Value |
|---|---|
| Files | Standard output: two JSON lines. Standard error: trace lines, error lines and log lines. `--pcm FILE`: raw audio. |
| Format | The JSON lines are ASCII, one object on each line, with a newline (`0x0a`) at the end. |
| Byte order | The JSON lines are text. The PCM file is little-endian. |
| Writer | `src/agent/main.zig` |
| Readers | `tools/agent_sessions.sh`, `tools/agent_traces.sh` |

## Input

The command line is `flashbackz-agent [OPTIONS] [ASSET_PATH...]`. `ASSET_PATH` is a floppy image
or a directory extracted from one. The run needs the two disks
([floppy-image.md](floppy-image.md)).

### Options shared with the SDL host

| Option | Content |
|---|---|
| `--scene NAME` | Start on the title menu (`menu`), or in a level: `jungle`, `city`, `tower`, `earth_city`, `spaceport`, `alien_surface` or `alien_base`. Default: the introduction. |
| `--saves DIR` | The save directory ([save.md](save.md)). Default for the agent: the records stay in memory. |
| `--data DIR` | Read the data set from `DIR` ([data-set.md](data-set.md)). Default: extract it in memory. |
| `--extract DIR` | Write the data set into `DIR`, a new or empty directory. Then write the report on standard output, and stop. Only `--names` and `ASSET_PATH` can go with it. |
| `--names FILE` | With `--extract` only: the naming overlay ([naming-overlay.md](naming-overlay.md)). |
| `--megadrive FILE` | The Mega Drive cartridge, for its tunes ([megadrive-cartridge.md](megadrive-cartridge.md)). |

### Options of the agent host

The options from `--key` to `--stall` can occur more than one time. The other options can occur
only one time.

| Option | Value | Content |
|---|---|---|
| `--frames N` | 0 to 2^64 - 1 | Run N host frames. Default: 120. |
| `--key F:KEY` | | At frame F, `key_down` and then `key_up` of KEY. |
| `--key-down F:KEY` | | At frame F, `key_down` of KEY. |
| `--key-up F:KEY` | | At frame F, `key_up` of KEY. |
| `--key-repeat F:KEY` | | At frame F, `key_down` of KEY with the repeat flag. |
| `--button-down F:BUTTON` | | At frame F, `controller_button_down` of BUTTON on pad 0. |
| `--button-up F:BUTTON` | | At frame F, `controller_button_up` of BUTTON on pad 0. |
| `--axis F:AXIS:VALUE` | VALUE: -32768 to 32767 | At frame F, `controller_axis` of AXIS on pad 0. |
| `--save F:SLOT` | | After the update of frame F, save the level in play into the record SLOT. |
| `--load F:SLOT` | | After the update of frame F, load the record SLOT. |
| `--stall F:MS` | MS: 0 to 3600000 | Before the update of frame F, advance the clock by MS milliseconds. |
| `--trace` | | Write the trace lines on standard error. |
| `--pcm FILE` | | Write the audio that the game queued into FILE. |

The values use this syntax:

- An option takes its value from the next argument, or from the text after `=`
  (`--frames=60`).
- `F` is a host frame, a decimal integer from 0.
- `KEY` is a name of `platform.Key`, for example `f2` or `left`.
  [sdl-event-log.md](sdl-event-log.md) lists the names.
- `BUTTON` is a name of `platform.ControllerButton`, for example `a` or `dpad_left`.
- `AXIS` is a name of `platform.ControllerAxis`, for example `left_x`.
- `SLOT` is a record name. The game uses `QUICK` and `SAVE1` to `SAVE8`.

An example: `--key-down 5:escape --key-up 8:escape` holds Escape from frame 5 to frame 8. The
events are of the kinds that [sdl-event-log.md](sdl-event-log.md#kinds) gives.

When a `--button-down`, `--button-up` or `--axis` option is present, the host adds a
`controller_added` event for pad 0 at time 0, before frame 0. The model of this pad has the GUID
`00000000000000000000000000a9e47d` ([settings.md](settings.md)).

### Host frame

The clock starts at 0. Each host frame does these steps:

1. Add the events of the frame, all with the current time of the clock. Add the key events
   first, then the button events, then the axis events. Each group is in the order of the
   command line.
2. Advance the clock for each `--stall` of the frame.
3. Call `game.update` one time. If the game stops, go to the end of the run.
4. With `--trace`, write a walk line if necessary.
5. Do the `--save` and `--load` options of the frame, in the order of the command line.
6. Advance the clock by 16666666 ns (1/60 s, rounded down).

The game gets an event at the first update with a clock at or after the time of the event. The
first update starts the platform. It reads events only when the game starts in a level.

At the end of the run, the host writes the PCM file, and then the two lines on standard output.

## Standard output

### Line 1

```json
{"updates":120,"frames_presented":120,"events_consumed":2,"state_hash":"0123456789abcdef","frame_hash":"fedcba9876543210"}
```

| Field | Type | Content |
|---|---|---|
| `updates` | integer | The game updates that ran. |
| `frames_presented` | integer | The pictures that the game presented. |
| `events_consumed` | integer | The device events that the game read. |
| `state_hash` | string | The hash of the state of the scene in play, in 16 lower-case hexadecimal digits (see below). |
| `frame_hash` | string | The Wyhash (seed 0) of the last presented picture as 256 × 224 palette indices, in 16 lower-case hexadecimal digits. 0 when the game presented no picture. |

The frame hash covers only the palette indices. A change of the palette, or of the save picture
on a slot page, does not change it.

The state hash is a Wyhash of the state of the scene in play. The function `stateHash` of each
scene gives the bytes. For `level`, the seed is the level index (`jungle` 0 to `alien_base` 6).
For the other scenes, the seed is 0. The hash covers these values:

| Scene | Values |
|---|---|
| `level` | For each character: state, cursor, x, y, room, health, counter, active, direction, sprite, mirrored, first item and next item. Then the score, the view room and the random state. |
| `menu` | The stage, the page, the selected row, the difficulty, the next difficulty, the selected level, the typed code, the part of the introduction and the frame of the film in play. |
| `continue_game` | The choice, the pulse and its direction, the countdown, the pending and held presses, the view, the score, the clock, the result and the queued events. |
| `ending` | The stage, the end flag, the film, the frame of the film, and the step and the typed characters of the credits. |

### Line 2

The fields of line 2 depend on the scene in play.

| Scene | Line 2 |
|---|---|
| A level | `{"scene":"level","level":L,"difficulty":D,"room":R,"x":X,"y":Y,"score":S,"catch_up_walks":C,"film":F,"sound_fx":B,"joystick":J}` |
| The title scene | `{"scene":"menu","stage":T,"page":P,"selected":A,"film_frame":N}` |
| Another scene | `{"scene":K}`, with K `"continue_game"` or `"ending"` |

| Field | Type | Content |
|---|---|---|
| `level` | string | The level: `jungle`, `city`, `tower`, `earth_city`, `spaceport`, `alien_surface` or `alien_base`. |
| `difficulty` | string | `easy`, `normal` or `expert`. |
| `room`, `x`, `y` | integers | The room and the position of Conrad (character 0). `x` and `y` can be less than 0. |
| `score` | integer | The score. |
| `catch_up_walks` | integer | The catch-up walks of this level: how many times the host was late. |
| `film` | boolean | A film plays. |
| `sound_fx`, `joystick` | booleans | The settings ([settings.md](settings.md)). |
| `stage` | string | `branding`, `introduction`, `game_over`, `menu`, `ready`, `demo_ready`, `ending_ready` or `quit`. |
| `page` | string | `main`, `skill`, `info`, `password` or `load`. |
| `selected` | string | The selected row of the main page: `start`, `load`, `skill`, `password`, `info`, `demo` or `quit`. |
| `film_frame` | integer or `null` | The frame of the film of the title scene, or `null` when no film plays. |

## Standard error

### Trace lines

With `--trace`, the host writes these lines during the run:

| Line | When |
|---|---|
| `{"frame":F,"walks":W,"state_hash":"H"}` | After the update of frame F, when a level is in play and its walk count is not the last count written. |
| `{"frame":F,"save":"SLOT"}` | After each `--save` of frame F, also when the save fails. |
| `{"frame":F,"load":"SLOT"}` | After each `--load` of frame F, also when the load fails. |

- `W` is the count of walks of the level since it started or loaded. It can increase by more than
  1 between two lines, because one update can walk the characters more than one time.
- `H` is the state hash of the level after the update, as in line 1.
- `SLOT` is the text of the option, without JSON escapes.

### Other lines

| Line | Content |
|---|---|
| `flashbackz-agent: save SLOT: ERROR` | A `--save` failed. `ERROR` is the name of the error, for example `NothingToSave`. |
| `flashbackz-agent: load SLOT: ERROR` | A `--load` failed, for example `NotFound` or `OtherDataSet` ([save.md](save.md#checks)). |
| `info: ...`, `warning: ...`, `error: ...` | Log lines of the game. |
| `flashbackz-agent: ...`, then the usage lines | An option has an error (see [Checks](#checks)). The status is 2. |
| `flashbackz-agent: cannot open the ...` | A provider does not open (a disk, the save directory, the data set or the cartridge). The status is 2. |
| `flashbackz-agent: the game's files are missing: ...` | The command line has no `ASSET_PATH`. The status is 2. |

The host writes these lines before the two lines of standard output.

## PCM file

The file holds the samples that the game queued and that the queue of the agent accepted. It has
no header. The samples are i16, interleaved, 2 channels at 44100 Hz.

## Exit status

| Status | Condition |
|---|---|
| 0 | The run ended. |
| 1 | The game, the `--extract` command or the write of the PCM file failed. |
| 2 | An option has an error, the game files are missing, or a provider does not open. |

## Tools

### `tools/agent_sessions.sh`

The script runs scripted sessions. Its output must agree with the accepted output
`tools/agent_sessions.txt`:

```sh
tools/agent_sessions.sh AGENT DISK1 DISK2 | diff tools/agent_sessions.txt -
```

For each session, the script:

1. Makes a new save directory in a temporary directory, and gives it with `--saves`.
2. Runs the agent with the session options and the two disks. It merges standard error into
   standard output.
3. Writes `NAME: "state_hash":"H","frame_hash":"F" LINE2`. The hashes come from the first line of
   the output, and `LINE2` is the last line.
4. Writes `  settings: RECORD` when the session wrote a `SETTINGS` record. `RECORD` is the record
   without spaces and newlines.

Most sessions start with `--key-down 5:escape --key-up 8:escape`: this skips the film at the
start of the level. The script deletes the temporary directory at the end.

### `tools/agent_traces.sh`

The script plays a session of 2400 frames in each level with `--trace`. Its output must agree
with the accepted output `tools/agent_traces.txt`:

```sh
tools/agent_traces.sh AGENT DISK1 DISK2 | diff tools/agent_traces.txt -
```

1. Make the input: Escape from frame 5 to frame 8. Then from frame 40, hold each key group for
   150 frames, with 30 frames between groups. The groups are, in order: `right`; `left_shift`
   and `right`; `space`; `left`; `down`; `up`; `right`; `space` and `right`; `left`.
2. For each of the seven levels, empty the save directory and run the agent with
   `--scene LEVEL --frames 2400 --trace`.
3. Merge standard error into standard output, and remove the lines that start with `info:`.
4. Write `LEVEL: N lines, H`. `N` is the count of the lines. `H` is the first 16 hexadecimal
   digits of the SHA-256 of the lines, each with its newline.

The lines of step 3 include the trace lines and the two lines of standard output.

## Checks

The agent host refuses these command lines. It writes `flashbackz-agent: MESSAGE` and the usage
lines on standard error, and stops with status 2.

| Condition | MESSAGE |
|---|---|
| An option is not known. | `unknown option OPTION` |
| An option has no value. | `OPTION needs a value` |
| An option without a value, for example `--trace`, has `=`. | `OPTION takes no value` |
| An option that can occur only one time occurs again. | `OPTION may be given only once` |
| A value does not parse or is out of its range. A name is not in its enum. A path is empty. | `invalid value for OPTION: VALUE` |
| `--names` occurs without `--extract`. | `--names needs --extract` |
| `--extract` occurs with an option other than `--names`. | `OPTION cannot be used with --extract` |
| The command line has more than two `ASSET_PATH`. | `unexpected argument ARGUMENT` |
| `--scene` gives a level, and the command line has no `ASSET_PATH`. | `missing ASSET_PATH (--scene with a level needs the disks)` |

The tools refuse nothing. `tools/agent_sessions.sh` ignores the exit status of the agent. When the
agent fails, the session line has no hashes, and the last error line takes the place of line 2.
`tools/agent_traces.sh` counts and hashes the error lines as it does the trace lines.

## Sources

- `src/agent/main.zig`, `src/agent/backend.zig` (`inject`, `advance`, `pollEvents`,
  `controllerModel`).
- `src/shared/game.zig` (`stateHash`, `update`, `present`, `saveGame`, `loadGame`).
- `src/shared/scenes/level.zig`, `src/shared/scenes/front_end.zig`,
  `src/shared/scenes/continue_game.zig`, `src/shared/scenes/ending.zig` (`stateHash`).
- `src/shared/audio/output.zig` (the audio format), `src/native/cli.zig` (the shared options).
- `tools/agent_sessions.sh`, `tools/agent_traces.sh`.
