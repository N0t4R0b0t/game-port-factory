#!/usr/bin/env bash
# Regenerates games/dizzy/recipe/MAP.md -- the game's map topology, which
# games/README.md already lists as part of every game's recipe.
#
# The --special notes are the one thing no extraction can produce: rooms
# 0-3 hold art and look like rooms, but they are selected by code, never
# walked into (checkfireout swaps room 36 for room 2 when the fire is
# out; checkbeanstalk does the same for 58 -> 1). Source of truth for
# them is HERE, the way regen_art.sh is the source of truth for
# roompack's flags.
#
# --built lists the rooms the TAPE build contains (T0255): derived from the
# build itself, the `fdb rNN_room_desc` lines of room_desc_table in
# target/room36.asm (the -run build is the subset outside `if TAPE_ROOMS`;
# the tape/floppy builds hold every line).  No hand-kept list.
set -euo pipefail
cd "$(dirname "$0")/../../.."          # repo root
ASM=ports/dizzy-coco2/target/room36.asm
BUILT=$(awk '/^room_desc_table/{on=1;next} on && /^[[:space:]]*fdb 0[[:space:]]*$/{exit} on' "$ASM" \
  | grep -oE 'fdb r[0-9]+_room_desc' | grep -oE '[0-9]+' | sort -n | paste -sd, -)
# room 2 (the fire overlay of 36) has no table entry but is built
BUILT=$(printf '%s,2' "$BUILT" | tr ',' '\n' | sort -nu | paste -sd, -)
[ -n "$BUILT" ] || { echo "genmap.sh: could not derive the built rooms from $ASM" >&2; exit 2; }
echo "genmap.sh: built rooms: $BUILT"

TOOL=ports/dizzy-coco2/tools/roommap/target/release/roommap
[ -x "$TOOL" ] || cargo build --release --manifest-path ports/dizzy-coco2/tools/roommap/Cargo.toml

"$TOOL" \
  --rooms ports/dizzy-coco2/extracted/rooms.json \
  --actors ports/dizzy-coco2/extracted/actors.json \
  --built "$BUILT" \
  --title "Fantasy World Dizzy (ZX Spectrum, 1989)" \
  --special "0=the title screen" \
  --special "1=room 58 redrawn with the beanstalk grown (checkbeanstalk, X-ALL.TXT ~5478)" \
  --special "2=room 36 redrawn with the fire out (checkfireout, ~5491) -- this port builds it as the fire overlay" \
  --special "3=the heart demo shown on reaching Daisy (theheartdemo, ~3518)" \
  --output games/dizzy/recipe/MAP.md
