#!/usr/bin/env bash
# Play the ORIGINAL ZX Spectrum game yourself, warped straight into a room.
#   tools/zx_play.sh [ROOM X Y]      default: room 93 (The Cloud Castle) floor
# X is in the original's units (port pixel x / 4), Y is port y.
# The tape loads at full speed (~15 s), then the game runs at real speed in a
# MAME window with infinite lives. Keys: Z left, X right, SPACE jump,
# ENTER pick up / use. Close the window to quit.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOM=${1:-93} WX=${2:-36} WY=${3:-168}
TAG=play ROOM=$ROOM WX=$WX WY=$WY STRAT=play exec mame spectrum \
  -rompath source/zx/roms -cass "source/Dizzy III - Fantasy World Dizzy (1989)(Codemasters).tzx" \
  -autoboot_script harness/zx_warp.lua -window -nothrottle
