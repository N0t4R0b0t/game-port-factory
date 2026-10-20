#!/usr/bin/env bash
# T0233: play the ORIGINAL ZX Spectrum game (MAME `spectrum`, the user's tape) through the SAME route as tools/playthrough.sh, keys only.
#   tools/zx_playthrough.sh [--from N] [--until N] [--record OUT.avi] [--no-record]
# Engine: harness/playthrough.lua with PT_MACHINE=zx (machine layer harness/pt_mach_zx.lua); the route is harness/playthrough_route.lua
# (per-machine overrides in R.override.zx).  Headless, -nothrottle.  The tape load is ~394 emulated seconds (~8 s real) and is not recorded:
# --record starts MAME's AVI writer at the game's first frame (harness/playthrough.lua zx_begin) and writes the RAW AVI to OUT.avi
# (~16 MB per emulated second; tools/side_by_side.sh encodes it).  Checkpoints: target/zxpt_states (MAME save states, one per segment).
# Verdict: `ZXPLAYTHROUGH PASS segments=N deaths=D ...` (exit 0), FAIL, or PARTIAL (exit 0 only with --until).
set -uo pipefail
cd "$(dirname "$0")/.."
FROM=1; UNTIL=999; UNTIL_GIVEN=0; REC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM=$2; shift 2;;
    --until) UNTIL=$2; UNTIL_GIVEN=1; shift 2;;
    --record) REC=$2; shift 2;;
    --no-record) REC=""; shift;;
    *) echo "unknown arg $1" >&2; exit 2;;
  esac
done
TAPE="source/Dizzy III - Fantasy World Dizzy (1989)(Codemasters).tzx"
[ -f "$TAPE" ] || { echo "missing $TAPE" >&2; exit 2; }
[ -f target/pt_masks/room36.msk ] || python3 tools/pt_dump_masks.py
mkdir -p target/zxpt_states
export PT_MACHINE=zx PT_FROM=$FROM PT_UNTIL=$UNTIL PT_STATEDIR=target/zxpt_states PT_ROOT=.
[ -n "$REC" ] && { mkdir -p "$(dirname "$REC")"; export ZX_REC="$(realpath -m "$REC")"; export PT_TAIL_FRAMES=${PT_TAIL_FRAMES:-350}; }   # ~7 s on the finished title
LOG=${PT_LOG:-/tmp/zx_playthrough_last.log}
timeout ${PT_TIMEOUT:-3000} mame spectrum -rompath source/zx/roms -cass "$TAPE" -video none -sound none -nothrottle \
  -state_directory "$PWD/target/zxpt_states" -seconds_to_run ${PT_SECONDS:-6000} \
  -autoboot_script harness/playthrough.lua 2>&1 | grep -v 'load_dat' | sed -e 's/^PLAYTHROUGH /ZXPLAYTHROUGH /' | tee "$LOG"
if grep -q '^ZXPLAYTHROUGH PASS' "$LOG"; then exit 0; fi
if [ $UNTIL_GIVEN = 1 ] && grep -q '^ZXPLAYTHROUGH PARTIAL' "$LOG"; then exit 0; fi
exit 1
