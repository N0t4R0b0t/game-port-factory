#!/usr/bin/env bash
# T0233 verifier for the ZX playthrough bot and its pairing with the CoCo bot (a cheaper tier can run it; exit 0 = every check passed).
#
#   tools/verify_zx_playthrough.sh                 run tools/zx_playthrough.sh TWICE from boot (~4 min each, headless) and check
#   tools/verify_zx_playthrough.sh --logs A.log B.log [--coco-log C.log]    check logs that already exist (no emulator)
#
# Checks:
#  1. both ZX runs end with `ZXPLAYTHROUGH PASS segments=<n> deaths=0` and the win lines WIN/TITLE are present (win at coins=30);
#  2. the two logs are byte-identical apart from the speed line (the bot is deterministic);
#  3. PAIRING: every port segment 1..N appears exactly once as `pair=` among the ZX segments (ZX-only segments say pair=none);
#  4. KEPT IN STEP: for every paired segment the ZX's end room equals the CoCo's end room (from the `(checkpoint n saved: room=R` lines).  Exceptions are
#     listed in EXPECTED_ROOM_DIFF below with the reason; any other mismatch fails.
#  5. (if --coco-log is given or target/pt_tmp/coco.log exists) both logs carry SEGSTART t= for every segment, monotonic increasing.
set -uo pipefail
cd "$(dirname "$0")/.."
# plan segment index -> reason (T0237: the CoCo bot plays the SAME 106-segment plan as the ZX bot since T0235 made the port need the room-93 egg too, so the
# end-room comparison is by segment INDEX; the original legitimately ends these segments in another room)
declare -A EXPECTED_ROOM_DIFF=( [61]="the port carries whoever stands at the open well mouth down into 23 at once; the original's mouth is a hole Dizzy walks into (ZX 62.1)" )
A=""; B=""; COCO=target/pt_tmp/coco.log
if [ "${1:-}" = "--logs" ]; then A=$2; B=$3; shift 3; [ "${1:-}" = "--coco-log" ] && COCO=$2
else
  A=/tmp/zx_verify_1.log; B=/tmp/zx_verify_2.log
  PT_LOG=$A tools/zx_playthrough.sh > /dev/null 2>&1; PT_LOG=$B tools/zx_playthrough.sh > /dev/null 2>&1
fi
fail=0
ok()  { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fail=1; }
for L in "$A" "$B"; do
  v=$(grep -E '^ZXPLAYTHROUGH (PASS|FAIL|PARTIAL)' "$L" | tail -1)
  if echo "$v" | grep -q '^ZXPLAYTHROUGH PASS segments=[0-9]* deaths=0 '; then ok "$L: $v"; else bad "$L: ${v:-no verdict line}"; fi
  w=$(grep -E '^WIN t=.* coins=30' "$L" | head -1); t=$(grep -E '^TITLE t=' "$L" | head -1)
  [ -n "$w" ] && [ -n "$t" ] && ok "$L: win + title lines present" || bad "$L: WIN/TITLE lines missing (WIN must be at coins=30)"
done
if diff <(grep -v '^Average speed\|^REC0\|^END' "$A") <(grep -v '^Average speed\|^REC0\|^END' "$B") > /dev/null; then ok "the two logs are identical (deterministic)"; else bad "the two logs differ"; fi
# pairing
awk '/^SEGSTART/ { for (i=4;i<=NF;i++) if ($i ~ /^pair=/) { split($i,b,"="); if (b[2]!="none") c[b[2]]++ } }
     END { n=0; for (k in c) { n++; if (c[k]!=1) { printf "port segment %s appears %d times\n", k, c[k]; e=1 } } mx=0; for (k in c) if (k+0>mx) mx=k+0
           if (n!=mx) { printf "paired %d distinct port segments but the highest is %d\n", n, mx; e=1 } exit e }' "$A" && ok "pairing: every port segment appears exactly once" || bad "pairing"
# end rooms
if [ -f "$COCO" ]; then
  awk -v exc="$(for k in "${!EXPECTED_ROOM_DIFF[@]}"; do printf '%s ' "$k"; done)" '
    BEGIN { split(exc, ex, " "); for (i in ex) skip[ex[i]] = 1 }
    FNR==NR { if (match($0, /\(checkpoint [0-9]+ saved: room=[0-9]+/)) { s=substr($0,RSTART,RLENGTH); split(s,a," "); n=a[2]; split(a[4],r,"="); cr[n]=r[2] } next }
    /^SEGSTART/ { k=$2; if (k+0>mx) mx=k+0 }
    match($0, /\(checkpoint [0-9]+ saved: room=[0-9]+/) { s=substr($0,RSTART,RLENGTH); split(s,a," "); n=a[2]; split(a[4],r,"="); zr[n]=r[2] }
    END { cmp=0; bad=0; for (k=1;k<=mx;k++) if ((k in zr) && (k in cr)) { cmp++; if (zr[k]!=cr[k] && !(k in skip)) { bad++; printf "    segment %d: ZX ends in room %s, CoCo in room %s\n", k, zr[k], cr[k] } }
          printf "    compared %d paired segments, %d unexpected end-room mismatches\n", cmp, bad; exit (bad>0) }' "$COCO" "$A" && ok "kept in step: paired segments end in the same room (except the documented ones)" || bad "end rooms differ"
  # timestamps
  for L in "$A" "$COCO"; do
    awk '/^SEGSTART/ { split($3,a,"="); t=a[2]+0; if (t<=last) e=1; last=t; n++ } END { exit (e || n==0) }' "$L" && ok "$L: SEGSTART times strictly increasing" || bad "$L: SEGSTART times missing or not increasing"
  done
else
  echo "  skip CoCo comparisons ($COCO not found: run PT_LOG=$COCO tools/playthrough.sh --no-build)"
fi
[ $fail = 0 ] && echo "VERIFY ZXPLAYTHROUGH: ALL CHECKS PASSED" || echo "VERIFY ZXPLAYTHROUGH: FAILED"
exit $fail
