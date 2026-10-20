#!/usr/bin/env bash
# T0240 verifier: the CoCo analog joystick (tape build).  Last line: "VERIFY_JOYSTICK PASS" (exit 0) or
# "VERIFY_JOYSTICK FAIL: ..." (exit 1).
#   ROOM36_REF=/path/room36_ref.bin tools/verify_joystick.sh   # tape_pack.sh x2 + cmp room36.bin + the MAME harness
#   NOBUILD=1 tools/verify_joystick.sh                         # harness only, on the current target/
# What it proves (harness/joystick.lua, ~35 checks): centre = still; full tilt = the key's 4 px every update (same
# positions); partial tilt = n/4 of that, never faster; left mirrors right; dead zone holds under noise; fire = jump
# with the direction latched at take-off; fire dismisses a message box; an unarmed (pegged) stick is ignored; the DAC
# is only touched muted by joy_read, parked at 0, and the sound code's own DAC writes are identical with the stick.
set -uo pipefail
cd "$(dirname "$0")/.."
fails=(); bad(){ fails+=("$1"); echo "   FAIL: $1"; }
if [ -z "${NOBUILD:-}" ]; then
  tools/tape_pack.sh > /tmp/verify_joystick_pack1.log 2>&1 || bad "tape_pack.sh run 1"
  tools/tape_pack.sh > /tmp/verify_joystick_pack2.log 2>&1 || bad "tape_pack.sh run 2"
  grep -E 'persistent FREE' /tmp/verify_joystick_pack2.log
fi
if [ -n "${ROOM36_REF:-}" ]; then cmp target/room36.bin "$ROOM36_REF" && echo "   room36.bin identical" || bad "room36.bin differs"; fi
out=$(env DIZZY_BIN=target/room36_tape.bin DIZZY_MAP=target/room36_tape.map \
  timeout 580 mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 1200 \
  -autoboot_script harness/joystick.lua 2>&1 | grep -a 'JOYSTICK')
echo "$out" | grep -a -E 'JOYSTICK (FAIL|SWEEP|INFO|SUMMARY)'
echo "$out" | grep -q 'JOYSTICK SUMMARY pass=[0-9]* fail=0' || bad "joystick.lua"
n=$(echo "$out" | sed -n 's/.*JOYSTICK SUMMARY pass=\([0-9]*\).*/\1/p'); [ "${n:-0}" -ge 34 ] || bad "joystick.lua ran only ${n:-0} checks (want >= 34)"
if [ ${#fails[@]} -eq 0 ]; then echo "VERIFY_JOYSTICK PASS"; exit 0; fi
echo "VERIFY_JOYSTICK FAIL: ${fails[*]}"; exit 1
