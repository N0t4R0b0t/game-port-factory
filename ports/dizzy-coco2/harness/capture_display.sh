#!/usr/bin/env bash
# Capture the REAL RENDERED DISPLAY of a target binary -- what a person
# looking at the screen would see, including VDG mode, colour set and NTSC
# artifact colouring.
#
# WHY THIS EXISTS (read before deleting it as redundant):
# capture_pmode4.sh pulls $4000 over GDB and decodes it as 1bpp 256x192.
# That verifies the BLIT, but it assumes the answer to the question it is
# supposedly checking -- it decodes the buffer the way we intended it to be
# displayed, so a wrong video mode is completely invisible to it. A single
# wrong PIA1 mode nibble ($E instead of $F) had this port displaying CG6
# (128x192, FOUR colour, 2 bits/pixel) instead of PMODE4/RG6 for days:
# half the horizontal resolution silently discarded and all art turned to
# buff/cyan/magenta mush, while every headless check stayed green and a
# human screenshot got blamed on "a display-environment issue".
# See NOTES.md T0028.
#
# Rule of thumb: capture_pmode4.sh answers "did we draw the right bytes?",
# this answers "does the machine SHOW the right picture?". A visual claim
# needs both.
#
# Usage: capture_display.sh BINARY.bin OUT.png [TICKS]
#   TICKS (default 400) = how long to run before snapshotting; raise it if
#   the program needs longer to reach the state you want to see.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BIN="${1:?usage: capture_display.sh BINARY.bin OUT.png [TICKS]}"
OUT="${2:?usage: capture_display.sh BINARY.bin OUT.png [TICKS]}"
TICKS="${3:-400}"

SHOTDIR="$(mktemp -d)"
trap 'rm -rf "$SHOTDIR"' EXIT

DIZZY_BIN="$(realpath "$BIN")" DIZZY_TICKS="$TICKS" \
  mame coco2b -ext "" -autoboot_script "$HERE/mame_snapshot.lua" \
    -snapshot_directory "$SHOTDIR" -snapname 'shot%i' \
    -video none -sound none -nothrottle -seconds_to_run $(( TICKS / 30 + 8 )) \
    >/dev/null 2>&1 || true

SHOT="$(find "$SHOTDIR" -name '*.png' | head -1)"
if [ -z "$SHOT" ]; then
    echo "capture_display.sh: no snapshot produced (did the binary run?)" >&2
    exit 1
fi
cp "$SHOT" "$OUT"
echo "wrote $OUT (rendered display)"
