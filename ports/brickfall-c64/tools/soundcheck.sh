#!/bin/bash
# Verifier for the SID effect triggers: runs scenarios under headless x64sc via
# `gpfdiff probe` and asserts the sound engine's state (V_IDX/V_TIM/V_WAVE at
# $c108..$c10d) started the expected sequence for each event. Sequence offsets are
# derived from brickfall.vs, so reordering the data cannot silently break it.
# Usage: soundcheck.sh <gpfdiff> <recipe dir>   (run from ports/brickfall-c64/target)
set -u
GPFDIFF=$1; RECIPE=$2
lab() { grep -E "^al C:[0-9a-f]+ \.$1\$" brickfall.vs | sed 's/al C:\([0-9a-f]*\) .*/\1/'; }
base=$((16#$(lab seqdata)))
# V_IDX after a start = sequence offset + 3 (first note), as 2 hex digits
idx() { printf '%02x' $(( 16#$(lab $1) - base + 3 )); }
fail=0
probe() { $GPFDIFF probe --platform c64 --prg brickfall.prg --labels brickfall.vs \
            --scenario $RECIPE/scenarios/$1.toml --addr c108 --len 6; }
# need <scenario> <voice 0|1> <seq label> <what>
need() {
  local out; out=$(cat "$OUT.$1")
  local i; i=$(idx $3)
  local re
  if [ "$2" = 0 ]; then re="^[0-9]+ $i[0-9a-f]{10}\$"; else re="^[0-9]+ [0-9a-f]{2}$i[0-9a-f]{8}\$"; fi
  if echo "$out" | grep -Eq "$re"; then echo "ok   $1: $4 (voice $2 started $3)"; else echo "FAIL $1: $4 (voice $2 never started $3, idx $i)"; fail=1; fi
}
OUT=$(mktemp -d)/p
for s in launch_left paddle_zones wall_bounces game_over full_win; do
  probe $s > $OUT.$s || { echo "FAIL probe $s"; cat $OUT.$s; exit 1; }
done
need launch_left   0 s_launch "launch"
need launch_left   0 s_b4     "bottom brick row (10 pts) pitch"
need launch_left   1 s_miss   "miss"
need paddle_zones  0 s_paddle "paddle bounce"
need wall_bounces  0 s_wall   "wall bounce"
need game_over     1 s_over   "game over jingle"
for r in 0 1 2 3 4; do need full_win 0 s_b$r "brick hit, row $r"; done
need full_win      1 s_win    "win jingle"
# the first logged point (step 0, nothing happened yet) must be silent
head -1 $OUT.full_win | grep -q '^0 ffff00000000$' && echo "ok   step 0 silent" || { echo "FAIL step 0 not silent: $(head -1 $OUT.full_win)"; fail=1; }
[ $fail = 0 ] && echo "SOUNDCHECK PASS" || { echo "SOUNDCHECK FAIL"; exit 1; }
