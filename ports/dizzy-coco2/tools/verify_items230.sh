#!/usr/bin/env bash
# T0230 verifier: black hole (TAPE_HOLE=1), the whiskey (drop message, 255-tick drunk timer, the four
# tumbles, empty-bottle name), the manure message, and the inventory names of the egg / potion /
# crowbar / window frame. Last line: "VERIFY_ITEMS230 PASS" (exit 0) or "VERIFY_ITEMS230 FAIL: ..." (exit 1).
#   ROOM36_REF=/path/room36_ref.bin tools/verify_items230.sh   # tape_pack.sh x2 + all checks + cmp room36.bin
#   NOBUILD=1 tools/verify_items230.sh                         # checks only, on the current target/
#   DUMPDIR=dir                                                # pixel dumps (harness/pmode4_to_png.py FILE out.png)
# Neighbours: NOBUILD=1 tools/verify_items227.sh / verify_people229.sh / verify_daisy228.sh.
set -uo pipefail
cd "$(dirname "$0")/.."
fails=(); note(){ echo "-- $*"; }; bad(){ fails+=("$1"); echo "   FAIL: $1"; }
grep -q '^TAPE_HOLE     equ 1' target/room36.asm || bad "TAPE_HOLE is not 1 in target/room36.asm"
if [ -z "${NOBUILD:-}" ]; then
  tools/tape_pack.sh > /tmp/verify_items230_pack1.log 2>&1 || bad "tape_pack.sh run 1"
  tools/tape_pack.sh > /tmp/verify_items230_pack2.log 2>&1 || bad "tape_pack.sh run 2"
  grep -E 'persistent FREE' /tmp/verify_items230_pack2.log
  free=$(sed -n 's/.*persistent FREE total:.*= \([0-9]*\) bytes.*/\1/p' /tmp/verify_items230_pack2.log | tail -1)
  [ "${free:-0}" -ge 200 ] || bad "persistent free total ${free:-?} < 200"
fi
if [ -n "${ROOM36_REF:-}" ]; then cmp target/room36.bin "$ROOM36_REF" && echo "   room36.bin identical" || bad "room36.bin differs"; fi
cargo build --release --manifest-path tools/roompack/Cargo.toml >/dev/null 2>&1
out=$(tools/roompack/target/release/verify_tape_text)
echo "$out" | grep -E 'holdinghole|dropwhiskey|pickupmanure|emptybottle|goldenegg|sleeppotion|crowbarmess|windowmess|VERIFY_TAPE_TEXT'
for m in dropwhiskeymess pickupmanuremess emptybottlemess goldeneggmess sleeppotionmess crowbarmess windowmess holdingholemess; do
  echo "$out" | grep -q "PASS msg_[a-z_]* == X-ALL $m" || bad "verify_tape_text: $m"; done
echo "$out" | tail -1 | grep -q 'VERIFY_TAPE_TEXT PASS' || bad "verify_tape_text"
tools/dte/target/release/dte --root . selftest 2>&1 | tail -1 | grep -q 'ALL PASS' || bad "dte selftest"
python3 tools/ramaudit.py > /tmp/verify_items230_ramaudit.log 2>&1 || bad "ramaudit.py"
mame_run() { local n=$1 secs=$2; shift 2
  env DIZZY_BIN=target/room36_tape.bin DIZZY_MAP=target/room36_tape.map "$@" \
    timeout 580 mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run "$secs" \
    -autoboot_script "harness/$n.lua" 2>&1 | grep -v 'LUA ERROR\|load_dat'; }
note "MAME: tape_items230.lua (whiskey + tumbles + controls, manure, names, game-over reset)"
out=$(mame_run tape_items230 1800 ${DUMPDIR:+DUMPDIR=$DUMPDIR})
echo "$out" | grep -E 'ITEMS230 (FAIL|SUMMARY)|INFO tumble'
echo "$out" | grep -q 'ITEMS230 SUMMARY pass=[0-9]* fail=0' || bad "tape_items230.lua"
n=$(echo "$out" | sed -n 's/.*ITEMS230 SUMMARY pass=\([0-9]*\).*/\1/p'); [ "${n:-0}" -ge 36 ] || bad "tape_items230.lua ran only ${n:-0} checks (want >= 36)"
note "MAME: tape_items227.lua with the hole built (46 checks)"
out=$(mame_run tape_items227 1800)
echo "$out" | grep -E 'ITEMS227 (FAIL|SUMMARY)'
n=$(echo "$out" | sed -n 's/.*ITEMS227 SUMMARY pass=\([0-9]*\) fail=0.*/\1/p'); [ "${n:-0}" -ge 46 ] || bad "tape_items227.lua: ${n:-0} checks, want >= 46 with TAPE_HOLE=1"
if [ ${#fails[@]} -eq 0 ]; then echo "VERIFY_ITEMS230 PASS"; exit 0; fi
echo "VERIFY_ITEMS230 FAIL: ${fails[*]}"; exit 1
