#!/usr/bin/env bash
# T0227 verifier: the rug + room 94 daggers/carpets, the bag (inventory 3 -> 4), per-record inventory
# names (full bucket, door knocker, rug; tape-table items looked up in the right table), and the black
# hole when built (TAPE_HOLE=1 in target/room36.asm; off by default, see NOTES T0227). Also re-runs the
# T0226 harness and every neighbour that shares the pickup/drop/inventory paths. A cheaper tier can
# run this and read the last line: "VERIFY_ITEMS227 PASS" (exit 0) or
# "VERIFY_ITEMS227 FAIL: ..." (exit 1).
#
#   ROOM36_REF=/path/room36_ref.bin tools/verify_items227.sh   # build (tape_pack.sh x2) + all checks + cmp room36.bin
#   NOBUILD=1 tools/verify_items227.sh                         # checks only, on the current target/
#
# Needs: mame (coco2b), xroar (real-tape-boot check), lwasm, cargo, python3.
# One emulator at a time. A GDB TimeoutError in tape_boot_regions.py is the XRoar stub's
# known timing flake: it is re-run up to seven times (it timed out ~half the runs on this machine, independent of the content).
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
  note "tools/tape_pack.sh (twice: addresses settle on the 2nd run; the 3rd must be byte-identical to the 2nd)"
  tools/tape_pack.sh > /tmp/verify_items227_pack1.log 2>&1 || bad "tape_pack.sh run 1 failed (see /tmp/verify_items227_pack1.log)"
  tools/tape_pack.sh > /tmp/verify_items227_pack2.log 2>&1 || bad "tape_pack.sh run 2 failed (see /tmp/verify_items227_pack2.log)"
  cp target/room36_tape.bin /tmp/verify_items227_tape2.bin
  tools/tape_pack.sh > /tmp/verify_items227_pack3.log 2>&1 || bad "tape_pack.sh run 3 failed"
  cmp -s target/room36_tape.bin /tmp/verify_items227_tape2.bin || bad "tape bin differs between the 2nd and 3rd tape_pack.sh run"
  grep -E 'TAPE_LOW_REGION|tape-only region|persistent FREE' /tmp/verify_items227_pack3.log
fi
if [ -n "${ROOM36_REF:-}" ]; then
  cmp target/room36.bin "$ROOM36_REF" && echo "   room36.bin (-run build) identical to $ROOM36_REF" || bad "room36.bin differs from $ROOM36_REF"
fi

note "text: every message token-for-token against X-ALL.TXT, banner names against rooms.json, DTE round trip"
[ -x tools/roompack/target/release/verify_tape_text ] || cargo build --release --manifest-path tools/roompack/Cargo.toml >/dev/null 2>&1
out=$(tools/roompack/target/release/verify_tape_text)
echo "$out" | grep -E 'usedoorknocker|fillbucket|usepickaxe|userug|holdinghole|fullbucket|knocker|rug|banner table|VERIFY_TAPE_TEXT'
echo "$out" | tail -1 | grep -q 'VERIFY_TAPE_TEXT PASS' || bad "verify_tape_text"
tools/dte/target/release/dte --root . selftest 2>&1 | tail -1 | grep -q 'ALL PASS' || bad "dte selftest"
python3 tools/ramaudit.py > /tmp/verify_items227_ramaudit.log 2>&1 || bad "ramaudit.py"

note "MAME: rug + room-94 daggers/carpets, inventory names, bag, (hole), game-over reset"
out=$(mame_run tape_items227 1800)
echo "$out" | grep -E 'ITEMS227 (FAIL|SUMMARY)'
echo "$out" | grep -q 'ITEMS227 SUMMARY pass=[0-9]* fail=0' || bad "tape_items227.lua"
echo "$out" | grep -q 'ITEMS227 FAIL' && bad "tape_items227.lua has FAIL lines"
n=$(echo "$out" | sed -n 's/.*ITEMS227 SUMMARY pass=\([0-9]*\).*/\1/p'); [ "${n:-0}" -ge 40 ] || bad "tape_items227.lua ran only ${n:-0} checks (want >= 40 with the hole off, >= 46 with it on)"

note "MAME: T0226 harness (banners, knocker/door, bucket chain, pickaxe/rock) still passes"
out=$(mame_run tape_items226 1800)
echo "$out" | grep -E 'ITEMS226 (FAIL|SUMMARY)'
echo "$out" | grep -q 'ITEMS226 SUMMARY pass=[0-9]* fail=0' || bad "tape_items226.lua"

note "MAME: the beanstalk chain now goes knocker -> door -> 83 -> empty bucket -> well -> full bucket -> water"
python3 tools/derive_cmask.py --dump-stalk target/cmask_stalk_expected.bin >/dev/null || bad "derive_cmask --dump-stalk"
out=$(mame_run tape_beanstalk 1500 CMASK_STALK=target/cmask_stalk_expected.bin)
echo "$out" | grep -E 'BEANSTALK (FAIL|SUMMARY)|chain [0-9]/4'
echo "$out" | grep -q 'BEANSTALK SUMMARY pass=[0-9]* fail=0' || bad "tape_beanstalk.lua"
echo "$out" | grep -q 'chain 4/4: the full bucket is picked up' || bad "tape_beanstalk.lua did not reach the full-bucket pickup"

note "neighbours that share the drop/trigger/room-load/banner paths"
out=$(mame_run cmaskverify 900 CMASK_TAPE=1 CMASK_EXPECTED=target/cmask_expected_tape.bin)
echo "$out" | grep 'CMASKSUM'
echo "$out" | grep -q 'CMASKSUM 19 rooms, 19 PASS, 0 FAIL, 0 SKIP' || bad "cmaskverify 19/0/0"
TITLE_IMG=$(mktemp /tmp/title_raw.XXXXXX); python3 tools/title_image.py research/D3-prior-art/info/dizzy3_title.png "$TITLE_IMG" >/dev/null || bad "title_image.py"   # T0232: gameover_tape needs the reference title image
out=$(mame_run gameover_tape 300 TITLE_IMAGE="$TITLE_IMG"); echo "$out" | grep -q 'GAMEOVER_TAPE PASS' || bad "gameover_tape"
out=$(mame_run tape_log48 900); echo "$out" | grep 'SUMMARY'; echo "$out" | grep -q 'LOG48 SUMMARY pass=[0-9]* fail=0' || bad "tape_log48"
out=$(mame_run tape_dozyfloat 600); echo "$out" | grep 'SUMMARY'; echo "$out" | grep -q 'DOZYFLOAT SUMMARY pass=[0-9]* fail=0' || bad "tape_dozyfloat"
out=$(mame_run tape_item_pickup 900); echo "$out" | grep -q 'TAPEITEMSUM [0-9]* ok, 0 fail' || bad "tape_item_pickup"
out=$(mame_run inv_full 900); echo "$out" | grep -q 'INVFULL SUMMARY pass=6 fail=0' || bad "inv_full"
out=$(mame_run tape_hawk 900); echo "$out" | grep -q 'TAPEHAWK PASS' && ! echo "$out" | grep -q 'TAPEHAWK FAIL' || bad "tape_hawk"

note "real tape boot (XRoar): every segment incl. LOW3/LOW4 byte-identical, free tails survive"
out=$(python3 harness/tape_boot_regions.py 2>&1)
for try in 2 3 4 5 6 7 8; do
  if echo "$out" | grep -q TimeoutError; then note "GDB TimeoutError: re-running (attempt $try of 8)"; out=$(python3 harness/tape_boot_regions.py 2>&1); fi
done
echo "$out" | grep -E 'REGION3|REGION4|TAPE_BOOT_REGIONS'
echo "$out" | grep -q 'TAPE_BOOT_REGIONS PASS' || bad "tape_boot_regions.py"

if [ ${#fails[@]} -eq 0 ]; then echo "VERIFY_ITEMS227 PASS"; exit 0; fi
echo "VERIFY_ITEMS227 FAIL: ${fails[*]}"; exit 1
