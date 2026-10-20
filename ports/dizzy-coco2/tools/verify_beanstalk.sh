#!/usr/bin/env bash
# T0223 verifier: the shopkeeper -> bean -> plant -> water -> beanstalk chain
# and TAPE_LOW_REGION3, end to end. A cheaper tier can run this and read the
# last line: "VERIFY_BEANSTALK PASS" (exit 0) or "VERIFY_BEANSTALK FAIL ..." (exit 1).
#
#   tools/verify_beanstalk.sh                  # build (tape_pack.sh twice) + all checks
#   NOBUILD=1 tools/verify_beanstalk.sh        # checks only, on the current target/
#   ROOM36_REF=/path/room36_ref.bin tools/verify_beanstalk.sh   # also cmp target/room36.bin
#
# Needs: mame (coco2b), xroar (the real-tape-boot check), lwasm, cargo, python3.
# Runs ONE emulator at a time. A GDB TimeoutError in tape_boot_regions.py is the
# XRoar stub's known timing flake (T0219/T0227): it is re-run once.
set -uo pipefail
cd "$(dirname "$0")/.."
fails=()
note() { echo "-- $*"; }
bad() { fails+=("$1"); echo "   FAIL: $1"; }

mame_run() {  # name seconds [ENV=..]...  -> prints the harness's own lines to $LOG
  local n=$1 secs=$2; shift 2
  env DIZZY_BIN=target/room36_tape.bin DIZZY_MAP=target/room36_tape.map "$@" \
    timeout 580 mame coco2b -ext "" -nothrottle -video none -sound none \
    -seconds_to_run "$secs" -autoboot_script "harness/$n.lua" 2>&1 | grep -v 'LUA ERROR\|load_dat'
}

if [ -z "${NOBUILD:-}" ]; then
  note "tools/tape_pack.sh (twice: hole addresses settle on the 2nd run)"
  tools/tape_pack.sh > /tmp/verify_beanstalk_pack1.log 2>&1 || bad "tape_pack.sh run 1 failed (see /tmp/verify_beanstalk_pack1.log)"
  tools/tape_pack.sh > /tmp/verify_beanstalk_pack2.log 2>&1 || bad "tape_pack.sh run 2 failed (see /tmp/verify_beanstalk_pack2.log)"
  grep -E 'TAPE_LOW_REGION|tape-only region' /tmp/verify_beanstalk_pack2.log
fi
if [ -n "${ROOM36_REF:-}" ]; then
  cmp target/room36.bin "$ROOM36_REF" && echo "   room36.bin identical to $ROOM36_REF" || bad "room36.bin differs from $ROOM36_REF"
fi

note "text: token-for-token against X-ALL.TXT, DTE round trip"
[ -x tools/roompack/target/release/verify_tape_text ] || cargo build --release --manifest-path tools/roompack/Cargo.toml >/dev/null 2>&1
tools/roompack/target/release/verify_tape_text | tail -1 | grep -q 'VERIFY_TAPE_TEXT PASS' || bad "verify_tape_text"
tools/dte/target/release/dte selftest 2>&1 | tail -1 | grep -q 'ALL PASS' || bad "dte selftest"

note "offline stalk mask + MAME beanstalk harness"
python3 tools/derive_cmask.py --dump-stalk target/cmask_stalk_expected.bin >/dev/null || bad "derive_cmask --dump-stalk"
out=$(mame_run tape_beanstalk 1500 CMASK_STALK=target/cmask_stalk_expected.bin)
echo "$out" | grep -E 'BEANSTALK (FAIL|SUMMARY)'
echo "$out" | grep -q 'BEANSTALK SUMMARY pass=[0-9]* fail=0' || bad "tape_beanstalk.lua"
echo "$out" | grep -q 'BEANSTALK FAIL' && bad "tape_beanstalk.lua has FAIL lines"

note "neighbours that share the reset/trigger/room-load paths"
out=$(mame_run cmaskverify 900 CMASK_TAPE=1 CMASK_EXPECTED=target/cmask_expected_tape.bin)
echo "$out" | grep 'CMASKSUM'
echo "$out" | grep -q 'CMASKSUM 19 rooms, 19 PASS, 0 FAIL, 0 SKIP' || bad "cmaskverify 19/0/0"
TITLE_IMG=$(mktemp /tmp/title_raw.XXXXXX); python3 tools/title_image.py research/D3-prior-art/info/dizzy3_title.png "$TITLE_IMG" >/dev/null || bad "title_image.py"   # T0232: gameover_tape needs the reference title image
out=$(mame_run gameover_tape 300 TITLE_IMAGE="$TITLE_IMG")
echo "$out" | grep -q 'GAMEOVER_TAPE PASS' || bad "gameover_tape"
out=$(mame_run tape_log48 600)
echo "$out" | grep 'SUMMARY'
echo "$out" | grep -q 'LOG48 SUMMARY pass=[0-9]* fail=0' || bad "tape_log48"
out=$(mame_run tape_dozyfloat 600)
echo "$out" | grep 'SUMMARY'
echo "$out" | grep -q 'DOZYFLOAT SUMMARY pass=[0-9]* fail=0' || bad "tape_dozyfloat"

note "real tape boot (XRoar): every segment incl. TAPE_LOW_REGION3 byte-identical, free tails survive"
out=$(python3 harness/tape_boot_regions.py 2>&1)
if echo "$out" | grep -q TimeoutError; then note "GDB TimeoutError: re-running once"; out=$(python3 harness/tape_boot_regions.py 2>&1); fi
echo "$out" | grep -E 'REGION3|TAPE_BOOT_REGIONS'
echo "$out" | grep -q 'TAPE_BOOT_REGIONS PASS' || bad "tape_boot_regions.py"

if [ ${#fails[@]} -eq 0 ]; then echo "VERIFY_BEANSTALK PASS"; exit 0; fi
echo "VERIFY_BEANSTALK FAIL: ${fails[*]}"; exit 1
