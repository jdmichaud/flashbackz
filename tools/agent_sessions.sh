#!/bin/bash
# Plays scripted sessions in the agent host and prints, for each, its state and frame hashes,
# where it ended and the settings it saved. The output of the last accepted build is
# `agent_sessions.txt` beside this script; a change that should not alter play keeps it:
#
#   tools/agent_sessions.sh zig-out/bin/flashbackz-agent disk1.img disk2.img | diff tools/agent_sessions.txt -
#
# Each session saves into its own temporary directory, never the user's.
set -eu
agent="${1:?usage: agent_sessions.sh <agent> <disk1.img> <disk2.img>}"
disks=("${2:?the first floppy image}" "${3:?the second floppy image}")
saves_root="$(mktemp -d)"
trap 'rm -rf "$saves_root"' EXIT

skip="--key-down 5:escape --key-up 8:escape" # the level's opening film
run() {
  local name=$1
  shift
  local saves="$saves_root/$name"
  mkdir "$saves"
  local out
  out="$("$agent" --saves "$saves" "$@" "${disks[@]}" 2>&1 || true)"
  local hashes
  hashes="$(printf '%s\n' "$out" | head -1 | grep -o '"state_hash":"[0-9a-f]*","frame_hash":"[0-9a-f]*"' || true)"
  echo "$name: $hashes $(printf '%s\n' "$out" | tail -1)"
  if [ -f "$saves/SETTINGS" ]; then echo "  settings: $(tr -d '\n ' <"$saves/SETTINGS")"; fi
}

# Play: walk, run, crouch, jump.
run walk --scene jungle --frames 420 $skip --key-down 40:right --key-up 120:right --key-down 130:left_shift --key-down 135:right --key-up 200:right --key-up 205:left_shift --key-down 220:down --key-up 240:down --key-down 260:up --key-up 300:up --key-down 320:space --key-up 330:space --key-down 360:left_shift --key-up 370:left_shift
# Options dialog: open, move, toggle, resume with Enter, then play on.
run options --scene jungle --frames 400 $skip --key-down 60:escape --key-up 66:escape --key 90:down --key 110:down --key 130:right --key 150:down --key 170:right --key 190:enter --key-down 220:right --key-up 300:right
# Options with keys held through it (released before it opens).
run options-held --scene jungle --frames 400 $skip --key-down 40:right --key-up 58:right --key-down 60:escape --key-up 66:escape --key 120:space --key-down 200:left --key-up 260:left
# Right held, the options dialog, Right released inside it, resume, Right held again.
run released-in-options --scene jungle --frames 260 $skip --key-down 40:right --key-down 50:escape --key-up 56:escape --key-up 60:right --key 70:enter --key-down 90:right --key-up 170:right
# Inventory: open, move, score, close.
run inventory --scene jungle --frames 360 $skip --key-down 60:tab --key-up 64:tab --key 100:right --key 120:left --key-down 140:space --key-up 170:space --key-down 200:tab --key-up 204:tab --key-down 240:right --key-up 300:right
# The inventory opened with Tab, closed with Backspace, then Right held.
run backspace-closes --scene jungle --frames 260 $skip --key-down 60:tab --key-up 64:tab --key-down 120:backspace --key-up 124:backspace --key-down 150:right --key-up 230:right
# Right pressed during the opening film and held after it.
run held-from-film --scene jungle --frames 200 --key-down 2:right --key-down 5:escape --key-up 8:escape --key-up 150:right
# Title menu (START, LOAD GAME, SKILL, PASSWORD...): down to SKILL, its page, EXPERT chosen,
# back on START: an expert game.
run title-skill --scene menu --frames 400 --key 30:down --key 50:down --key 70:up --key 80:down --key 90:enter --key 110:down --key 130:enter --key 160:enter
# The LOAD GAME page without saves: a slot chosen does nothing; Escape goes back.
run title-load --scene menu --frames 200 --key 30:down --key 50:enter --key 70:down --key 90:enter
run title-load-back --scene menu --frames 200 --key 30:down --key 50:enter --key 70:down --key 90:enter --key 120:escape
# Code entry: a wrong code.
run password --scene menu --frames 300 --key 30:down --key 40:down --key 50:down --key 70:enter --key 100:a --key 110:b --key 120:c --key 130:backspace --key 140:d --key 160:enter
# Abort from the options, then the continue screen. It reads held keys at its own pace: a
# one-frame Enter is not seen and the countdown ends the game; Enter held a moment retries.
run abort-retry --scene jungle --frames 700 $skip --key-down 60:escape --key-up 66:escape --key 90:up --key 110:enter --key 400:enter --key-down 600:right --key-up 680:right
run abort-retry-held --scene jungle --frames 700 $skip --key-down 60:escape --key-up 66:escape --key 90:up --key 110:enter --key-down 400:enter --key-up 420:enter --key-down 600:right --key-up 680:right
# The city: walk and the options.
run city --scene city --frames 400 $skip --key-down 40:left --key-up 140:left --key-down 160:escape --key-up 166:escape --key 200:escape --key-down 240:right --key-up 330:right

# Pads. Joystick on with J, then the pad walks, A and B act.
run pad --scene jungle --frames 360 $skip --key 30:j --button-down 60:dpad_right --button-up 140:dpad_right --button-down 150:a --button-up 160:a --button-down 170:b --button-up 175:b --button-down 200:dpad_left --button-up 260:dpad_left
# The pad's buttons without the joystick option do nothing.
run pad-off --scene jungle --frames 200 $skip --button-down 60:dpad_right --button-up 140:dpad_right
# Y opens the inventory, Y closes it, the D-pad walks.
run pad-inventory --scene jungle --frames 300 $skip --key 30:j --button-down 60:y --button-up 64:y --button-down 120:y --button-up 124:y --button-down 160:dpad_right --button-up 240:dpad_right
# The stick alone walks: it turns the Joystick option on.
run stick --scene jungle --frames 220 $skip --axis 60:left_x:30000 --axis 140:left_x:0
# START pauses; the D-pad goes to SOUND FX, right turns it off, B resumes, the stick walks.
run start-options --scene jungle --frames 320 $skip --button-down 40:start --button-up 44:start --button-down 70:dpad_down --button-up 72:dpad_down --button-down 90:dpad_right --button-up 92:dpad_right --button-down 110:b --button-up 114:b --axis 150:left_x:30000 --axis 230:left_x:0
# START, then B on ABORT GAME abandons, as A does (B chooses on menus): the continue screen.
run b-on-abort --scene jungle --frames 300 $skip --button-down 40:start --button-up 44:start --button-down 70:dpad_up --button-up 72:dpad_up --button-down 90:b --button-up 94:b --axis 150:left_x:30000 --axis 230:left_x:0
# START, A on ABORT GAME abandons; on the continue screen A retries.
run abort-retry-pad --scene jungle --frames 700 $skip --button-down 40:start --button-up 44:start --button-down 70:dpad_up --button-up 72:dpad_up --button-down 90:a --button-up 94:a --button-down 400:a --button-up 420:a --axis 600:left_x:30000 --axis 680:left_x:0
# The title: the D-pad to SKILL, A, down to EXPERT, A (back on START); A: an expert game.
run title-pad --scene menu --frames 400 --button-down 30:dpad_down --button-up 32:dpad_down --button-down 40:dpad_down --button-up 42:dpad_down --button-down 50:a --button-up 52:a --button-down 80:dpad_down --button-up 82:dpad_down --button-down 100:a --button-up 102:a --button-down 160:a --button-up 162:a
# The title: B on the main page chooses START, as A does.
run title-b --scene menu --frames 120 --button-down 30:b --button-up 32:b
