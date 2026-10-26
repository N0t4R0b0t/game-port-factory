#!/usr/bin/env bash
# T0255: room-by-room ACTOR FIDELITY of the CoCo port against the ZX Spectrum original.  Reusable; documented in tools/roomcmp/README.md.
#   tools/roomcmp.sh [--entries] [--rooms "36 49 ..." | all] [--ticks N] [--syms "a,b"] [-v] [--no-selftest]
#
# 1. --entries  runs BOTH playthrough bots (tape build, ZX tape) with PT_ENTRY_SAVE=1: a MAME state at the first entry into every room
#               (target/pt_states/coco2b/entry_<R>.sta, target/zxpt_states/spectrum/entry_<R>.sta).  Needs a fresh tape build
#               (tools/tape_pack.sh twice): a state only loads into the binary that wrote it.  ~40 s + ~4 min.
# 2. per room   harness/roomcmp_rec.lua loads each state and records N actor ticks (default 400) with no key pressed, on each machine; the
#               recording is made TWICE and the two files must be byte-identical (determinism) before they are compared.
# 3. tools/roomcmp (Rust, std only) pairs the ZX movingdata records with the port's actor slots and compares room/x/y/frame/colour per tick,
#               allowing a phase search; tools/roomcmp/expectations.toml names every EXPECTED deviation with its reason.
# Canary: `cargo test` in tools/roomcmp (the comparer must report MATCH for equal data, PHASE for a shift, DIVERGE for one changed value);
#         run first unless --no-selftest.
# Exit: 0 nothing unexpected, 1 the game differs (an unexpected DIVERGE / stale expectation), 2 the environment is wrong (missing state or
#       tool, recorder timeout, a non-deterministic recording).  Emulators run one at a time.
# Output: target/roomcmp/{zx,coco}_<R>.trace, report_<R>.txt, summary.txt (gitignored: derived from the user's media).
set -uo pipefail
cd "$(dirname "$0")/.."
ROOMS=all; TICKS=400; ENTRIES=0; VERB=""; SELFTEST=1; SYMS=${RC_SYMS:-}
while [ $# -gt 0 ]; do
  case "$1" in
    --rooms) ROOMS=$2; shift 2;;
    --ticks) TICKS=$2; shift 2;;
    --entries) ENTRIES=1; shift;;
    --syms) SYMS=${2//,/ }; shift 2;;
    -v) VERB=-v; shift;;
    --no-selftest) SELFTEST=0; shift;;
    *) echo "unknown arg $1" >&2; exit 2;;
  esac
done
OUT=target/roomcmp; mkdir -p "$OUT"
CMP=tools/roomcmp/target/release/roomcmp
[ -x "$CMP" ] || cargo build --release --manifest-path tools/roomcmp/Cargo.toml >/dev/null 2>&1 || { echo "cannot build tools/roomcmp" >&2; exit 2; }
if [ $SELFTEST = 1 ]; then
  cargo test -q --manifest-path tools/roomcmp/Cargo.toml >"$OUT/selftest.log" 2>&1 || { echo "roomcmp CANARY FAILED (see $OUT/selftest.log)" >&2; exit 2; }
fi
command -v mame >/dev/null || { echo "mame not found" >&2; exit 2; }
TAPE="source/Dizzy III - Fantasy World Dizzy (1989)(Codemasters).tzx"
[ -f "$TAPE" ] || { echo "missing $TAPE" >&2; exit 2; }
CODIR=target/pt_states/coco2b; ZXDIR=target/zxpt_states/spectrum
if [ $ENTRIES = 1 ]; then
  echo "== entry states + passive log: CoCo bot"; PT_ENTRY_SAVE=1 PT_RCLOG=$PWD/$OUT/coco_visits.log PT_LOG=$OUT/coco_bot.log tools/playthrough.sh --no-build >/dev/null 2>&1
  grep -q '^PLAYTHROUGH PASS' $OUT/coco_bot.log || { echo "CoCo bot did not pass ($OUT/coco_bot.log)" >&2; exit 2; }
  echo "== entry states + passive log: ZX bot"; PT_ENTRY_SAVE=1 PT_RCLOG=$PWD/$OUT/zx_visits.log PT_LOG=$OUT/zx_bot.log tools/zx_playthrough.sh >/dev/null 2>&1
  grep -q '^ZXPLAYTHROUGH PASS' $OUT/zx_bot.log || { echo "ZX bot did not pass ($OUT/zx_bot.log)" >&2; exit 2; }
fi
# a CoCo state only loads into the binary that wrote it: --entries stamps the binary, every other run checks the stamp
if [ $ENTRIES = 1 ]; then sha256sum target/room36_tape.bin > "$OUT/states.sha"; fi
if [ -f "$OUT/states.sha" ] && ! sha256sum -c --quiet "$OUT/states.sha" >/dev/null 2>&1; then
  echo "roomcmp: target/room36_tape.bin changed since the entry states were saved: rerun with --entries" >&2; exit 2
fi
if [ "$ROOMS" = all ]; then
  ROOMS=$(grep -oE 'fdb r[0-9]+_room_desc' target/room36.asm | grep -oE '[0-9]+' | sort -nu | tr '\n' ' ')
fi
common() { export PT_MODE=probe PT_PROBE=harness/roomcmp_rec.lua PT_EARLY=harness/roomcmp_rec.lua PT_ROOT=. PT_FROM=1 PT_UNTIL=999 RC_TICKS=$TICKS RC_SYMS="$SYMS"; }
rec_coco() {   # room outfile
  ( common; export DIZZY_BIN=target/room36_tape.bin DIZZY_MAP=target/room36_tape.map PT_STATEDIR=$CODIR PT_STATE=entry_$1 RC_OUT=$2
    unset PT_MACHINE
    timeout 300 mame coco2b -ext "" -video none -sound none -nothrottle -state_directory "$PWD/target/pt_states" -seconds_to_run 4000 \
      -autoboot_script harness/playthrough.lua 2>&1 | grep -v load_dat | grep -q '^ROOMCMP REC' )
}
rec_zx() {
  ( common; export PT_MACHINE=zx PT_STATEDIR=target/zxpt_states PT_STATE=entry_$1 RC_OUT=$2
    timeout 300 mame spectrum -rompath source/zx/roms -cass "$TAPE" -video none -sound none -nothrottle -state_directory "$PWD/target/zxpt_states" \
      -seconds_to_run 6000 -autoboot_script harness/playthrough.lua 2>&1 | grep -v load_dat | grep -q '^ROOMCMP REC' )
}
env_fail=0; game_fail=0
: > "$OUT/summary.txt"
for R in $ROOMS; do
  if [ ! -f "$CODIR/entry_$R.sta" ] || [ ! -f "$ZXDIR/entry_$R.sta" ]; then
    echo "ROOM $R: SKIP (no entry state on $([ -f "$CODIR/entry_$R.sta" ] || echo coco) $([ -f "$ZXDIR/entry_$R.sta" ] || echo zx): the route never enters it)" | tee -a "$OUT/summary.txt"; continue
  fi
  ok=1
  for m in coco zx; do
    rec_$m $R "$OUT/${m}_$R.trace" && rec_$m $R "$OUT/${m}_$R.b.trace" || { echo "ROOM $R: ENV recorder failed on $m"; ok=0; env_fail=1; break; }
    if ! cmp -s "$OUT/${m}_$R.trace" "$OUT/${m}_$R.b.trace"; then echo "ROOM $R: ENV $m recording is NOT deterministic ($OUT/${m}_$R.trace vs .b.trace)"; ok=0; env_fail=1; break; fi
    rm -f "$OUT/${m}_$R.b.trace"
  done
  [ $ok = 1 ] || continue
  $CMP --zx "$OUT/zx_$R.trace" --coco "$OUT/coco_$R.trace" --expect tools/roomcmp/expectations.toml $VERB > "$OUT/report_$R.txt"; rc=$?
  [ $rc = 1 ] && game_fail=1
  [ $rc = 2 ] && env_fail=1
  grep -v '^ROOMCMP\|^ROOM ' "$OUT/report_$R.txt" | sed "s/^/R$R /"
  tail -1 "$OUT/report_$R.txt" | tee -a "$OUT/summary.txt"
done
# the passive logs of the whole bot runs (written by --entries): run-length comparison of every actor's behaviour, phase-free
if [ -f "$OUT/zx_visits.log" ] && [ -f "$OUT/coco_visits.log" ]; then
  echo "== visits (passive logs of the two bot runs)"
  $CMP visits --zx "$OUT/zx_visits.log" --coco "$OUT/coco_visits.log" --expect tools/roomcmp/expectations.toml $VERB | tee "$OUT/visits_report.txt"
  [ ${PIPESTATUS[0]} = 1 ] && game_fail=1
fi
if [ $env_fail = 1 ]; then echo "ROOMCMP ENV FAIL"; exit 2; fi
if [ $game_fail = 1 ]; then echo "ROOMCMP FAIL (unexpected differences; see $OUT/report_*.txt)"; exit 1; fi
echo "ROOMCMP PASS"; exit 0
