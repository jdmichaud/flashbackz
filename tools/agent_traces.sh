#!/bin/bash
# Plays a 2,400-frame session on each level in the agent host (walking, running, jumping,
# crouching, shooting) and prints, per level, how many lines the walk trace has and a hash of it:
# every walk's state hash, in order. The output of the last accepted build is
# `agent_traces.txt` beside this script; a change that should not alter play keeps it:
#
#   tools/agent_traces.sh zig-out/bin/flashbackz-agent disk1.img disk2.img | diff tools/agent_traces.txt -
set -eu
agent="${1:?usage: agent_traces.sh <agent> <disk1.img> <disk2.img>}"
disks=("${2:?the first floppy image}" "${3:?the second floppy image}")
saves="$(mktemp -d)"
trap 'rm -rf "$saves"' EXIT

keys="--key-down 5:escape --key-up 8:escape"
frame=40
for held in right left_shift+right space left down up right space+right left; do
  for key in ${held//+/ }; do keys="$keys --key-down $frame:$key"; done
  frame=$((frame + 150))
  for key in ${held//+/ }; do keys="$keys --key-up $frame:$key"; done
  frame=$((frame + 30))
done
for level in jungle city tower earth_city spaceport alien_surface alien_base; do
  rm -rf "${saves:?}"/*
  # The trace is on stderr; log lines (`info: ...`) are not part of it.
  # shellcheck disable=SC2086
  trace="$("$agent" --saves "$saves" --scene "$level" --frames 2400 --trace $keys "${disks[@]}" 2>&1 | grep -v '^info:')"
  echo "$level: $(printf '%s\n' "$trace" | wc -l) lines, $(printf '%s\n' "$trace" | sha256sum | cut -c1-16)"
done
