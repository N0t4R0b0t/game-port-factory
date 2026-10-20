#!/usr/bin/env bash
# T0241 verifier: the FLOPPY build (target/dizzy.dsk). A cheaper tier can run this and read the last line:
# "VERIFY_FLOPPY241 PASS" (exit 0) or "VERIFY_FLOPPY241 FAIL: ..." (exit 1).
#
#   ROOM36_REF=/path/room36_ref.bin tools/verify_floppy241.sh   # build + every check + cmp of the -run build
#   NOBUILD=1 tools/verify_floppy241.sh                         # checks only, on the current target/
#   BOT=1 tools/verify_floppy241.sh                             # also the whole-game bot (tools/playthrough.sh --floppy, ~1 min)
#
# Needs: xroar, mame (+ source/roms/DSKBASIC.ROM for MAME's FDC), lwasm, cargo, python3.  No network.
# At most 2 emulators at a time (this script runs one at a time).  xroar's gdb stub is flaky: the xroar
# harnesses retry internally.
set -uo pipefail
cd "$(dirname "$0")/.."
fails=(); note(){ echo "-- $*"; }; bad(){ fails+=("$1"); echo "   FAIL: $1"; }
mame_fl() { local lua=$1 secs=$2; shift 2
  env FLOPPY_OVL_DIR=target/floppy DIZZY_BIN=target/room36_floppy.bin DIZZY_MAP=target/room36_floppy.map COPY=1 "$@" \
    timeout 900 tools/mame_floppy.sh -nothrottle -video none -sound none -seconds_to_run "$secs" \
    -autoboot_script "harness/$lua.lua" 2>&1 | grep -v 'LUA ERROR\|load_dat'; }

note "dskwriter / floppypack unit tests (directory + FAT round trip, granule/track-17 skip, spill guards)"
cargo test --release --manifest-path tools/dskwriter/Cargo.toml 2>&1 | grep -E "^test result" | tee /tmp/verify_floppy241_cargo.log
grep -Eq "FAILED|[1-9][0-9]* failed" /tmp/verify_floppy241_cargo.log && bad "cargo test"
[ "$(grep -c 'ok. ' /tmp/verify_floppy241_cargo.log)" -ge 3 ] || bad "cargo test did not run all three test binaries"
cargo build --release --manifest-path tools/dskwriter/Cargo.toml >/dev/null 2>&1

if [ -z "${NOBUILD:-}" ]; then
  note "tools/floppy_pack.sh (FLOPPY=1 pipeline x2 + loader + overlays + disk)"
  tools/floppy_pack.sh > /tmp/verify_floppy241_pack.log 2>&1 || { bad "floppy_pack.sh"; tail -15 /tmp/verify_floppy241_pack.log; }
  cp target/dizzy.dsk /tmp/verify_floppy241_1.dsk
  tools/floppy_pack.sh > /tmp/verify_floppy241_pack2.log 2>&1 || bad "floppy_pack.sh run 2"
  cmp -s target/dizzy.dsk /tmp/verify_floppy241_1.dsk || bad "dizzy.dsk differs between two floppy_pack.sh runs (not reproducible)"
  grep -E "loader DIZZY.BIN|persistent FREE" /tmp/verify_floppy241_pack2.log
fi
if [ -n "${ROOM36_REF:-}" ]; then
  tools/stage_pack.sh > /tmp/verify_floppy241_run.log 2>&1 || bad "stage_pack.sh (-run build)"
  cmp target/room36.bin "$ROOM36_REF" && echo "   room36.bin (-run build) identical to $ROOM36_REF" || bad "room36.bin differs from $ROOM36_REF"
fi
tools/dskwriter/target/release/dskwriter check target/dizzy.dsk | grep -q OK || bad "dskwriter check target/dizzy.dsk"
python3 tools/ramaudit.py --floppy > /tmp/verify_floppy241_ramaudit.log 2>&1 || bad "ramaudit.py --floppy"
free=$(sed -n 's/.*persistent FREE bytes.*: \([0-9]*\)$/\1/p' /tmp/verify_floppy241_ramaudit.log | head -1)
echo "   persistent FREE (floppy build): ${free:-?}  (tape build: $(python3 tools/ramaudit.py | sed -n 's/.*persistent FREE bytes.*: \([0-9]*\)$/\1/p'))"
[ "${free:-0}" -ge 2500 ] || bad "persistent free ${free:-?} < 2500"

note "xroar: Disk BASIC's own DIR lists the same files"
python3 harness/floppy_dir_check.py | tail -1 | grep -q '^PASS' || bad "floppy_dir_check.py"
note "xroar: REAL boot (LOADM\"DIZZY\":EXEC), every segment byte-identical, title playing"
python3 harness/floppy_boot_regions.py > /tmp/verify_floppy241_boot.log 2>&1; tail -1 /tmp/verify_floppy241_boot.log | grep -q '^PASS' || { bad "floppy_boot_regions.py"; tail -8 /tmp/verify_floppy241_boot.log; }
note "xroar: every overlay byte-identical, NMI error path, write path + host write-back (about a minute)"
python3 harness/floppy_overlays_xroar.py > /tmp/verify_floppy241_xr.log 2>&1; grep 'FLOPPY_XR SUMMARY' /tmp/verify_floppy241_xr.log
grep -q 'FLOPPY_XR SUMMARY pass=[0-9]* fail=0' /tmp/verify_floppy241_xr.log || { bad "floppy_overlays_xroar.py"; grep FAIL /tmp/verify_floppy241_xr.log; }

note "MAME + FDC: overlays, error and write paths"
out=$(mame_fl floppy_overlays 300); echo "$out" | grep -E 'FLOPPY_OVL (FAIL|SUMMARY)'
echo "$out" | grep -q 'FLOPPY_OVL SUMMARY pass=[0-9]* fail=0' || bad "floppy_overlays.lua"
note "MAME + FDC: game over -> title replay from the disk (2 rounds)"
out=$(mame_fl gameover_floppy 400 TITLE_IMAGE=/tmp/stage_floppy_title_raw.bin); echo "$out" | grep -E 'GAMEOVER' | cut -c1-120
echo "$out" | grep -q 'GAMEOVER_FLOPPY PASS' || bad "gameover_floppy.lua"
note "MAME + FDC: the heart demo overlay (Daisy's meeting + the win), pixel-exact vs the independent reference"
out=$(mame_fl tape_daisy94 1500); echo "$out" | grep -E 'DAISY94 (FAIL|SUMMARY)'
echo "$out" | grep -q 'DAISY94 SUMMARY pass=[0-9]* fail=0' || bad "tape_daisy94.lua on the floppy build"
out=$(mame_fl tape_daisy_ending 400); echo "$out" | grep -E 'TAPEDAISY' | cut -c1-100
echo "$out" | grep -q 'TAPEDAISY PASS' && echo "$out" | grep -q 'pixel diff 0' || bad "tape_daisy_ending.lua on the floppy build"

if [ -n "${BOT:-}" ]; then
  note "the whole-game bot on the floppy build (overlays load from the disk during it)"
  PT_LOG=/tmp/verify_floppy241_bot.log tools/playthrough.sh --floppy --no-build > /tmp/verify_floppy241_bot.out 2>&1 || bad "playthrough.sh --floppy"
  grep -E '^PLAYTHROUGH' /tmp/verify_floppy241_bot.log | cut -c1-160
  grep -q '^PLAYTHROUGH PASS.*deaths=0' /tmp/verify_floppy241_bot.log || bad "playthrough bot did not end in PLAYTHROUGH PASS deaths=0"
fi
if [ ${#fails[@]} -eq 0 ]; then echo "VERIFY_FLOPPY241 PASS"; exit 0; fi
echo "VERIFY_FLOPPY241 FAIL: ${fails[*]}"; exit 1
