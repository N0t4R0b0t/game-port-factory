#!/usr/bin/env bash
# T0229 verifier: Dylan (room 59) and Doug (room 88) talk dispatch, their texts, the crowbar that
# only appears after Doug's first talk. Last line: "VERIFY_PEOPLE229 PASS" (exit 0) or FAIL (exit 1).
#   NOBUILD=1 tools/verify_people229.sh            # checks only, on the current target/
#   tools/verify_people229.sh                      # tape_pack.sh x2 first
#   ROOM36_REF=/path/room36_ref.bin ...            # also cmp room36.bin
#   DUMPDIR=dir                                    # pixel dumps (harness/pmode4_to_png.py FILE out.png)
# Neighbours are covered by tools/verify_daisy228.sh (NOBUILD=1), run it after this one.
set -uo pipefail
cd "$(dirname "$0")/.."
fails=(); note(){ echo "-- $*"; }; bad(){ fails+=("$1"); echo "   FAIL: $1"; }
if [ -z "${NOBUILD:-}" ]; then
  tools/tape_pack.sh > /tmp/verify_people229_pack1.log 2>&1 || bad "tape_pack.sh run 1"
  tools/tape_pack.sh > /tmp/verify_people229_pack2.log 2>&1 || bad "tape_pack.sh run 2"
  grep -E 'persistent FREE' /tmp/verify_people229_pack2.log
fi
if [ -n "${ROOM36_REF:-}" ]; then cmp target/room36.bin "$ROOM36_REF" && echo "   room36.bin identical" || bad "room36.bin differs"; fi
out=$(tools/roompack/target/release/verify_tape_text)
echo "$out" | grep -E 'dylan|trance|doug|goonmy'
for m in 'msg_dylantalking == X-ALL dylantalking' 'msg_trance == X-ALL trancemess' 'msg_dougtalking == X-ALL dougtalking' 'msg_goonmyson == X-ALL goonmysonmess'; do
  echo "$out" | grep -q "PASS $m" || bad "verify_tape_text: $m"; done
echo "$out" | tail -1 | grep -q 'VERIFY_TAPE_TEXT PASS' || bad "verify_tape_text"
tools/dte/target/release/dte --root . selftest 2>&1 | tail -1 | grep -q 'ALL PASS' || bad "dte selftest"
python3 tools/ramaudit.py > /tmp/verify_people229_ramaudit.log 2>&1 || bad "ramaudit.py"
note "MAME: tape_people229.lua (real talks, crowbar, well lid, game-over reset)"
out=$(env DIZZY_BIN=target/room36_tape.bin DIZZY_MAP=target/room36_tape.map ${DUMPDIR:+PEOPLE_DUMP=$DUMPDIR} \
  timeout 580 mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 900 \
  -autoboot_script harness/tape_people229.lua 2>&1 | grep -v 'LUA ERROR\|load_dat')
echo "$out" | grep -E 'PEOPLE229 (FAIL|SUMMARY)'
echo "$out" | grep -q 'PEOPLE229 SUMMARY pass=[0-9]* fail=0' || bad "tape_people229.lua"
echo "$out" | grep -q 'PEOPLE229 FAIL' && bad "tape_people229.lua has FAIL lines"
n=$(echo "$out" | sed -n 's/.*PEOPLE229 SUMMARY pass=\([0-9]*\).*/\1/p'); [ "${n:-0}" -ge 30 ] || bad "tape_people229.lua ran only ${n:-0} checks (want >= 30)"
if [ ${#fails[@]} -eq 0 ]; then echo "VERIFY_PEOPLE229 PASS"; exit 0; fi
echo "VERIFY_PEOPLE229 FAIL: ${fails[*]}"; exit 1
