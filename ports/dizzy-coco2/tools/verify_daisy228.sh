#!/usr/bin/env bash
# T0228 verifier: Daisy in her prison (room 94: lift ride, meeting, two boxes, silent heart demo,
# daisy1 hidden until then) and the heart demo that ends the win sequence. A cheaper tier can run
# this and read the last line: "VERIFY_DAISY228 PASS" (exit 0) or "VERIFY_DAISY228 FAIL: ..." (exit 1).
#
#   ROOM36_REF=/path/room36_ref.bin tools/verify_daisy228.sh   # build (tape_pack.sh x3) + all checks + cmp room36.bin
#   NOBUILD=1 tools/verify_daisy228.sh                         # checks only, on the current target/
#   DUMPDIR=/tmp/x tools/verify_daisy228.sh                    # also writes the pixel dumps (view with harness/pmode4_to_png.py)
#
# Needs: mame (coco2b), xroar (real-tape-boot check), lwasm, cargo, python3.
# One emulator at a time. A GDB TimeoutError in tape_boot_regions.py is the XRoar stub's known timing
# flake: it is re-run up to seven times.
set -uo pipefail
cd "$(dirname "$0")/.."
fails=()
note() { echo "-- $*"; }
bad() { fails+=("$1"); echo "   FAIL: $1"; }

mame_run() {  # name seconds [ENV=..]...
  local n=$1 secs=$2; shift 2
  env DIZZY_BIN=target/room36_tape.bin DIZZY_MAP=target/room36_tape.map "$@" \
    timeout 580 mame coco2b -ext "" -nothrottle -video none -sound none \
    -seconds_to_run "$secs" -autoboot_script "harness/$n.lua" 2>&1 | grep -v 'LUA ERROR\|load_dat'
}

if [ -z "${NOBUILD:-}" ]; then
  note "tools/tape_pack.sh (three runs: addresses settle on the 2nd; the 3rd must be byte-identical to the 2nd)"
  tools/tape_pack.sh > /tmp/verify_daisy228_pack1.log 2>&1 || bad "tape_pack.sh run 1 failed (see /tmp/verify_daisy228_pack1.log)"
  tools/tape_pack.sh > /tmp/verify_daisy228_pack2.log 2>&1 || bad "tape_pack.sh run 2 failed (see /tmp/verify_daisy228_pack2.log)"
  cp target/room36_tape.bin /tmp/verify_daisy228_tape2.bin
  tools/tape_pack.sh > /tmp/verify_daisy228_pack3.log 2>&1 || bad "tape_pack.sh run 3 failed"
  cmp -s target/room36_tape.bin /tmp/verify_daisy228_tape2.bin || bad "tape bin differs between the 2nd and 3rd tape_pack.sh run"
  grep -E 'TAPE_LOW_REGION|tape-only region|persistent FREE' /tmp/verify_daisy228_pack3.log
fi
if [ -n "${ROOM36_REF:-}" ]; then
  cmp target/room36.bin "$ROOM36_REF" && echo "   room36.bin (-run build) identical to $ROOM36_REF" || bad "room36.bin differs from $ROOM36_REF"
fi

note "text: every message token-for-token against X-ALL.TXT (incl. gottodaisymess, daisyrunsmess), DTE round trip, RAM audit"
[ -x tools/roompack/target/release/verify_tape_text ] || cargo build --release --manifest-path tools/roompack/Cargo.toml >/dev/null 2>&1
out=$(tools/roompack/target/release/verify_tape_text)
echo "$out" | grep -E 'daisy|VERIFY_TAPE_TEXT'
echo "$out" | grep -q 'PASS msg_gottodaisy == X-ALL gottodaisymess' || bad "verify_tape_text: gottodaisymess not checked/passing"
echo "$out" | grep -q 'PASS msg_daisyruns == X-ALL daisyrunsmess' || bad "verify_tape_text: daisyrunsmess not checked/passing"
echo "$out" | tail -1 | grep -q 'VERIFY_TAPE_TEXT PASS' || bad "verify_tape_text"
tools/dte/target/release/dte --root . selftest 2>&1 | tail -1 | grep -q 'ALL PASS' || bad "dte selftest"
python3 tools/ramaudit.py > /tmp/verify_daisy228_ramaudit.log 2>&1 || bad "ramaudit.py"

note "MAME: Daisy in room 94, the meeting, the silent heart demo (pixel-exact vs an independent reference), game-over/win resets"
out=$(mame_run tape_daisy94 700 ${DUMPDIR:+DUMPDIR=$DUMPDIR})
echo "$out" | grep -E 'DAISY94 (FAIL|SUMMARY|INFO)'
echo "$out" | grep -q 'DAISY94 SUMMARY pass=[0-9]* fail=0' || bad "tape_daisy94.lua"
echo "$out" | grep -q 'DAISY94 FAIL' && bad "tape_daisy94.lua has FAIL lines"
n=$(echo "$out" | sed -n 's/.*DAISY94 SUMMARY pass=\([0-9]*\).*/\1/p'); [ "${n:-0}" -ge 50 ] || bad "tape_daisy94.lua ran only ${n:-0} checks (want >= 50)"

note "MAME: the win path (nag, 30 coins, boxes with the tune, then the heart demo, then the title, new game)"
out=$(mame_run tape_daisy_ending 250 ${DUMPDIR:+WIN_DUMP=$DUMPDIR})
echo "$out" | grep -E 'TAPEDAISY'
echo "$out" | grep -q 'TAPEDAISY PASS' && echo "$out" | grep -q 'heart demo after the last box: 255 updates, pixel diff 0' || bad "tape_daisy_ending.lua"

note "neighbours: lift/switch in 94, the actor draw path, the table's record order, resets, drops"
out=$(mame_run lift94 120); echo "$out" | grep -E 'LIFT94 (PASS|FAIL)'; echo "$out" | grep -q 'LIFT94 PASS' || bad "lift94"
out=$(mame_run tape_actor_reset 300); echo "$out" | grep -E 'PASS|FAIL' | tail -2; echo "$out" | grep -q 'FAIL' && bad "tape_actor_reset"
out=$(mame_run tape_coin94 200); echo "$out" | grep -E 'PASS|FAIL' | tail -2; echo "$out" | grep -q 'FAIL' && bad "tape_coin94"
out=$(mame_run tape_items227 1800)
echo "$out" | grep -E 'ITEMS227 (FAIL|SUMMARY)'
echo "$out" | grep -q 'ITEMS227 SUMMARY pass=[0-9]* fail=0' || bad "tape_items227.lua"
out=$(mame_run tape_items226 1800)
echo "$out" | grep -E 'ITEMS226 (FAIL|SUMMARY)'
echo "$out" | grep -q 'ITEMS226 SUMMARY pass=[0-9]* fail=0' || bad "tape_items226.lua"
python3 tools/derive_cmask.py --dump-stalk target/cmask_stalk_expected.bin >/dev/null || bad "derive_cmask --dump-stalk"
out=$(mame_run tape_beanstalk 1500 CMASK_STALK=target/cmask_stalk_expected.bin)
echo "$out" | grep -E 'BEANSTALK (FAIL|SUMMARY)'
echo "$out" | grep -q 'BEANSTALK SUMMARY pass=[0-9]* fail=0' || bad "tape_beanstalk.lua"
out=$(mame_run cmaskverify 900 CMASK_TAPE=1 CMASK_EXPECTED=target/cmask_expected_tape.bin)
echo "$out" | grep 'CMASKSUM'
echo "$out" | grep -q 'CMASKSUM 19 rooms, 19 PASS, 0 FAIL, 0 SKIP' || bad "cmaskverify 19/0/0"
TITLE_IMG=$(mktemp /tmp/title_raw.XXXXXX); python3 tools/title_image.py research/D3-prior-art/info/dizzy3_title.png "$TITLE_IMG" >/dev/null || bad "title_image.py"   # T0232: gameover_tape needs the reference title image
out=$(mame_run gameover_tape 300 TITLE_IMAGE="$TITLE_IMG"); echo "$out" | grep -q 'GAMEOVER_TAPE PASS' || bad "gameover_tape"
out=$(mame_run tape_log48 900); echo "$out" | grep -q 'LOG48 SUMMARY pass=[0-9]* fail=0' || bad "tape_log48"
out=$(mame_run tape_dozyfloat 600); echo "$out" | grep -q 'DOZYFLOAT SUMMARY pass=[0-9]* fail=0' || bad "tape_dozyfloat"
out=$(mame_run tape_hawk 900); echo "$out" | grep -q 'TAPEHAWK PASS' && ! echo "$out" | grep -q 'TAPEHAWK FAIL' || bad "tape_hawk"
out=$(mame_run tape_item_pickup 900); echo "$out" | grep -q 'TAPEITEMSUM [0-9]* ok, 0 fail' || bad "tape_item_pickup"
out=$(mame_run inv_full 900); echo "$out" | grep -q 'INVFULL SUMMARY pass=6 fail=0' || bad "inv_full"

note "real tape boot (XRoar): every segment byte-identical, free tails survive"
out=$(python3 harness/tape_boot_regions.py 2>&1)
for try in 2 3 4 5 6 7 8; do
  if echo "$out" | grep -q TimeoutError; then note "GDB TimeoutError: re-running (attempt $try of 8)"; out=$(python3 harness/tape_boot_regions.py 2>&1); fi
done
echo "$out" | grep -E 'REGION3|REGION4|TAPE_BOOT_REGIONS'
echo "$out" | grep -q 'TAPE_BOOT_REGIONS PASS' || bad "tape_boot_regions.py"

if [ ${#fails[@]} -eq 0 ]; then echo "VERIFY_DAISY228 PASS"; exit 0; fi
echo "VERIFY_DAISY228 FAIL: ${fails[*]}"; exit 1
