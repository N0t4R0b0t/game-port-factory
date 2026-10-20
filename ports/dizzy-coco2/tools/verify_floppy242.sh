#!/usr/bin/env bash
# T0242 verifier: quick save/load on the FLOPPY build.  Last line: "VERIFY_FLOPPY242 PASS" (exit 0) or "VERIFY_FLOPPY242 FAIL: ..." (exit 1).
#
#   ROOM36_REF=/path/room36_ref.bin tools/verify_floppy242.sh          # everything (about 25 min)
#   NOBUILD=1 tools/verify_floppy242.sh                                # on the current target/ (still regenerates the bot checkpoints)
#   REG=0 tools/verify_floppy242.sh                                    # skip the regression block (verify_floppy241 BOT=1 + tape/run checks)
#
# 1 state set: floppy_pack runs tools/state_set.py + floppy_state_check.py (every store in the listing classified); here the DYNAMIC half
#   too: the bot's 105 checkpoints, every byte that ever changed must be classified.
# 2 MAME round trip at 5 checkpoints (early/mid/late): S, perturb, L, the S-set byte-identical on every following pass + the framebuffer.
# 3 edge cases: empty slot, corrupted signature / other build / bad checksum, no disk, write-protected, key gates.
# 4 XRoar: real boot, S, power off, reboot the disk, L (write-back image).
# 5 the whole-game bot saves after segment N, plays on, loads, continues to the win.
# 6 regression: verify_floppy241.sh BOT=1, the -run build byte-identical, the tape build unchanged, verify_items230 NOBUILD=1.
set -uo pipefail
cd "$(dirname "$0")/.."
fails=(); note(){ echo "-- $*"; }; bad(){ fails+=("$1"); echo "   FAIL: $1"; }
mamefl() { COPY=1 timeout 900 tools/mame_floppy.sh -video none -sound none -nothrottle "$@" 2>&1 | grep -v 'LUA ERROR\|load_dat'; }

if [ -z "${NOBUILD:-}" ]; then
  note "tools/floppy_pack.sh (twice: reproducible; state manifest checked against every store)"
  tools/floppy_pack.sh > /tmp/v242_pack1.log 2>&1 || { bad "floppy_pack.sh"; tail -8 /tmp/v242_pack1.log; }
  cp target/dizzy.dsk /tmp/v242_1.dsk
  tools/floppy_pack.sh > /tmp/v242_pack2.log 2>&1 || bad "floppy_pack.sh run 2"
  cmp -s target/dizzy.dsk /tmp/v242_1.dsk || bad "dizzy.dsk not reproducible"
  grep -E "floppy_state_check|quick-save|FREE bytes|loader DIZZY" /tmp/v242_pack2.log
fi

note "the bot's checkpoints for THIS build (a MAME state carries the build's RAM: always regenerate)"
rm -rf target/pt_states_floppy
PT_LOG=/tmp/v242_bot0.log tools/playthrough.sh --floppy --no-build > /tmp/v242_bot0.out 2>&1 || bad "playthrough.sh --floppy (checkpoint run)"
grep '^PLAYTHROUGH' /tmp/v242_bot0.log | cut -c1-120
STATE="-state_directory $PWD/target/pt_states_floppy"

note "state set, DYNAMIC half: every byte that changed across the 105 checkpoints is classified"
mamefl -seconds_to_run 9000 $STATE -autoboot_script harness/floppy_state_dyn.lua | grep STATE_DYN
python3 tools/floppy_state_check.py || bad "floppy_state_check.py (with the checkpoint diff)"

note "MAME round trip (S, perturb, L, 60 passes byte-identical + framebuffer) at 5 points of the route"
for seg in 0 6 40 70 100; do
  out=$(SEG=$seg NPASS=60 mamefl -seconds_to_run 4000 $STATE -autoboot_script harness/quicksave.lua)
  echo "$out" | grep -E "QUICKSAVE (start|FAIL|SUMMARY)|DIFF"
  echo "$out" | grep -q "QUICKSAVE SUMMARY seg=$seg pass=5 fail=0" || bad "quicksave.lua seg=$seg"
done

note "edge cases (MAME)"
KEEP_DSK=/tmp/v242_saved.dsk SEG=0 NPASS=5 mamefl -seconds_to_run 300 -autoboot_script harness/quicksave.lua | grep SUMMARY
python3 - <<'PY'
d = bytearray(open('/tmp/v242_saved.dsk', 'rb').read()); off = 2 * 18 * 256
for n, i in (('badsig', 1), ('badver', 5), ('badsum', 100)):
    e = bytearray(d); e[off + i] ^= 0x20; open(f'/tmp/v242_{n}.dsk', 'wb').write(e)
PY
cp target/dizzy.dsk /tmp/v242_wp.dsk; chmod 444 /tmp/v242_wp.dsk
for c in empty gates badsig badver badsum; do
  extra=(); [ $c = badsig -o $c = badver -o $c = badsum ] && extra=(DSK=/tmp/v242_$c.dsk)
  out=$(env CASE=$c "${extra[@]}" bash -c 'COPY=1 timeout 300 tools/mame_floppy.sh -video none -sound none -nothrottle -seconds_to_run 300 -autoboot_script harness/quicksave_edges.lua 2>&1')
  echo "$out" | grep -E "QSEDGE (FAIL|SUMMARY)"; echo "$out" | grep -q "QSEDGE SUMMARY case=$c pass=[0-9]* fail=0" || bad "edge case $c"
done
out=$(CASE=nodisk NODISK=1 timeout 300 tools/mame_floppy.sh -video none -sound none -nothrottle -seconds_to_run 300 -autoboot_script harness/quicksave_edges.lua 2>&1)
echo "$out" | grep -E "QSEDGE (FAIL|SUMMARY)|box up"; echo "$out" | grep -q "QSEDGE SUMMARY case=nodisk pass=2 fail=0" || bad "edge case nodisk"
out=$(CASE=wp DSK=/tmp/v242_wp.dsk timeout 300 tools/mame_floppy.sh -video none -sound none -nothrottle -seconds_to_run 300 -autoboot_script harness/quicksave_edges.lua 2>&1)
echo "$out" | grep -E "QSEDGE (FAIL|SUMMARY)"; echo "$out" | grep -q "QSEDGE SUMMARY case=wp pass=2 fail=0" || bad "edge case wp"
tools/dskwriter/target/release/dskwriter check /tmp/v242_saved.dsk | grep -q OK || bad "the disk after a save fails dskwriter check"

note "XRoar: real boot -> S -> power off -> reboot -> L (write-back image)"
python3 harness/quicksave_xroar.py > /tmp/v242_xr.log 2>&1; grep -E "QSXR (FAIL|SUMMARY)" /tmp/v242_xr.log
grep -q "QSXR SUMMARY fail=0" /tmp/v242_xr.log || bad "quicksave_xroar.py"

note "the whole-game bot: save after segment N, play on K segments, load, continue to the win"
for nk in "30 5" "70 4" "100 3"; do
  set -- $nk
  PT_QS_N=$1 PT_QS_K=$2 PT_LOG=/tmp/v242_botqs$1.log tools/playthrough.sh --floppy --no-build > /tmp/v242_botqs$1.out 2>&1
  grep -E "quicksave|QUICKLOAD|^PLAYTHROUGH" /tmp/v242_botqs$1.log | cut -c1-140
  grep -q '^PLAYTHROUGH PASS.*deaths=0' /tmp/v242_botqs$1.log || bad "bot with a quick save/load at segment $1"
done

if [ "${REG:-1}" = 1 ]; then
  note "regression: verify_floppy241.sh BOT=1"
  env BOT=1 NOBUILD=1 ${ROOM36_REF:+ROOM36_REF=$ROOM36_REF} tools/verify_floppy241.sh > /tmp/v242_reg241.log 2>&1; tail -1 /tmp/v242_reg241.log
  tail -1 /tmp/v242_reg241.log | grep -q "VERIFY_FLOPPY241 PASS" || bad "verify_floppy241.sh"
  note "regression: -run and tape builds unchanged"
  tools/tape_pack.sh > /tmp/v242_tp1.log 2>&1; tools/tape_pack.sh > /tmp/v242_tp2.log 2>&1 || bad "tape_pack.sh"
  [ -n "${ROOM36_REF:-}" ] && { cmp target/room36.bin "$ROOM36_REF" && echo "   room36.bin identical to the reference" || bad "room36.bin differs"; }
  NOBUILD=1 tools/verify_items230.sh > /tmp/v242_items.log 2>&1; tail -1 /tmp/v242_items.log
  tail -1 /tmp/v242_items.log | grep -q "VERIFY_ITEMS230 PASS" || bad "verify_items230.sh"
  tools/floppy_pack.sh > /tmp/v242_pack3.log 2>&1 || bad "floppy_pack.sh after tape_pack"     # leave the floppy artifacts current
fi
if [ ${#fails[@]} -eq 0 ]; then echo "VERIFY_FLOPPY242 PASS"; exit 0; fi
echo "VERIFY_FLOPPY242 FAIL: ${fails[*]}"; exit 1
