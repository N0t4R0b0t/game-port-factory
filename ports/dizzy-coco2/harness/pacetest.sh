#!/usr/bin/env bash
# Build and run the port with a chosen frame-pacing budget, so the effect
# can be FELT rather than only measured (T0051).
#
#   ./harness/pacetest.sh 4    15 passes/sec  -- the shipped setting
#   ./harness/pacetest.sh 5    12 passes/sec  -- most even, uniformly slower
#   ./harness/pacetest.sh 8     7.5/sec       -- deliberately, obviously slow
#   ./harness/pacetest.sh off  no pacing at all (the pre-T0051 behaviour)
#
# The '8' setting exists to answer one question before any tuning: is the
# pacing doing ANYTHING in your emulator? If 8 does not feel obviously
# sluggish next to 4, then the pacing is inert here and the problem is in
# the mechanism, not in the choice of budget.
set -euo pipefail
cd "$(dirname "$0")/.."
ARG="${1:-4}"
BIN=/tmp/dizzy_pace_$ARG.bin
# T0095: room36.asm only assembles as a PACKED build now, and the packed
# blobs come from stage_pack.sh's raw pass. Run it first so the blobs match
# the current room data, then assemble the variant with -DSTAGE_LZ=1.
# Without this, both branches below hit the staging-overflow guard.
tools/stage_pack.sh > /dev/null
if [ "$ARG" = "off" ]; then
    lwasm --6809 --decb -DSTAGE_LZ=1 -DPACING=0 -o "$BIN" target/room36.asm
    echo "built $BIN (pacing disabled -- free-running, pre-T0051 behaviour)"
else
    sed "s/^FRAME_FIELDS equ 4/FRAME_FIELDS equ $ARG/" target/room36.asm > target/_pacetest.asm
    trap 'rm -f target/_pacetest.asm' EXIT
    lwasm --6809 --decb -DSTAGE_LZ=1 -o "$BIN" target/_pacetest.asm
    echo "built $BIN (FRAME_FIELDS=$ARG -> $(python3 -c "print(round(60/$ARG,1))") passes/sec target)"
fi
exec xroar -machine coco2bus -rompath source/roms -bas BASIC.ROM -extbas EXTBASIC.ROM -run "$BIN"
