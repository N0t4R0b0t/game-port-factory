#!/usr/bin/env bash
# Headless playtest driver for the CoCo2 port. Builds target/room36.asm
# fresh, loads it directly into MAME (no disk/cassette), drives the
# keyboard matrix from a scripted timeline, and prints a per-tick log of
# game state read straight out of RAM (position, lives, room, troll
# launch flag, inventory slot 0, ...) plus a snapshot PNG per log line.
#
# Ground truth for playtest verdicts should be the LOGGED MEMORY VALUES,
# not the screenshots: CoCo2 PMODE4's NTSC artifact-color rendering turns
# every sprite into a speckled dot pattern that is hard to visually parse
# even blown up -- screenshots are a secondary check, not the primary one
# (unlike zx_orig.sh's captures of the real ZX Spectrum, which render
# cleanly and ARE trustworthy to eyeball directly).
#
# Usage: coco_playtest.sh <script.lua> [seconds_to_run]
#   <script.lua> returns a table of {frame=N, label="...", fn=function(key,release_all) ... end}
#   frame is relative to the moment the game actually STARTS (T0129: not
#   the load frame -- the title screen and any intro message boxes block
#   on SPACE for a variable amount of time; coco_playtest.lua toggles
#   SPACE through them and only zeroes the timeline once cur_room/dizzy_y
#   confirm new_game has run). key(name, down) presses/releases one of
#   UP/DOWN/LEFT/RIGHT/SPACE. See playtest_script_example.lua.
#   DIZZY_START_ROOM (default 36) is the room the "really started" gate
#   waits for, if a build's START_ROOM was overridden.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="$(dirname "$HERE")"
TARGET="$PORT/target"
SCRIPT="${1:?usage: coco_playtest.sh <script.lua> [seconds_to_run]}"
SECS="${2:-30}"
OUT="${DIZZY_OUT:-/tmp/ptshots}"

BIN="$(mktemp /tmp/dizzy_pt_XXXX.bin)"
MAP="$(mktemp /tmp/dizzy_pt_XXXX.map)"
trap 'rm -f "$BIN" "$MAP"' EXIT

# T0095: must be a PACKED build -- a bare lwasm now refuses to assemble,
# and before that guard it emitted a binary that crashed on boot.
( cd "$TARGET/.." && tools/stage_pack.sh > /dev/null )
cp "$TARGET/room36.bin" "$BIN"
cp "$TARGET/room36.map" "$MAP"

mkdir -p "$OUT"
rm -f "$OUT"/pt*.png
DIZZY_BIN="$BIN" DIZZY_OUT="$OUT" DIZZY_SCRIPT="$SCRIPT" DIZZY_MAP="$MAP" \
  mame coco2b -ext "" -autoboot_script "$HERE/coco_playtest.lua" \
    -snapshot_directory "$OUT" -snapname 'pt%i' \
    -video none -sound none -nothrottle -seconds_to_run "$SECS" 2>&1 \
  | grep -v load_dat
echo "snapshots + log correspond 1:1 in $OUT (pt0000.png = 1st 'room=' log line, ...)"
