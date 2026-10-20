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
# --built must list the rooms this port actually builds -- keep it in
# step with tools/regen_art.sh.
set -euo pipefail
cd "$(dirname "$0")/../../.."          # repo root

TOOL=ports/dizzy-coco2/tools/roommap/target/release/roommap
[ -x "$TOOL" ] || cargo build --release --manifest-path ports/dizzy-coco2/tools/roommap/Cargo.toml

"$TOOL" \
  --rooms ports/dizzy-coco2/extracted/rooms.json \
  --actors ports/dizzy-coco2/extracted/actors.json \
  --built 2,35,36,51,52,53,54,68,69 \
  --title "Fantasy World Dizzy (ZX Spectrum, 1989)" \
  --special "0=the title screen" \
  --special "1=room 58 redrawn with the beanstalk grown (checkbeanstalk, X-ALL.TXT ~5478)" \
  --special "2=room 36 redrawn with the fire out (checkfireout, ~5491) -- this port builds it as the fire overlay" \
  --special "3=the heart demo shown on reaching Daisy (theheartdemo, ~3518)" \
  --output games/dizzy/recipe/MAP.md
