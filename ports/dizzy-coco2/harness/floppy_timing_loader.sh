#!/usr/bin/env bash
# T0241 -- XRoar emulated-seconds time of the BOOT LOADER (DIZZY.BIN streaming DIZZY.DAT), measured on
# the tape-recording clock: a TEST-ONLY copy of the loader (-DBOOT_MARKS) pulses the DAC around the load;
# nothing else differs (same segment table, same driver).  No gdb, no polling.  Needs target/dizzy.dsk
# and target/floppy/ from tools/floppy_pack.sh.   Usage: harness/floppy_timing_loader.sh
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=target/floppy; T=$(mktemp -d)
sym() { grep "^Symbol: $1 " target/room36_floppy.map | awk '{print $NF}'; }
lwasm --decb -DBOOT_MARKS=1 -DFDX_WRITE=0 -DFDX_SAVEVEC=0 -DLOADER_ORG=$((0x7600)) -DLOADER_STACK=$((0x7800)) \
      -DRES_FD_MOT=$((16#$(sym fd_mot))) -DRES_FD_HD=$((16#$(sym fd_hd))) -I"$OUT" -Itarget \
      -o "$T/DIZZY.BIN" --map="$T/loader.map" target/floppy_stage1.asm
echo "test loader: $(stat -c%s $T/DIZZY.BIN) bytes (production: $(stat -c%s $OUT/DIZZY.BIN))"
# a disk identical to target/dizzy.dsk except DIZZY.BIN
tools/dskwriter/target/release/dskwriter build "$T/timing.dsk" \
    --type 1 --at 0 --file DIZZY.OVL "$OUT/DIZZY.OVL" \
    --type 1 --at 4 --reserve 4608 --file DIZZY.SAV - \
    --type 1 --at 6 --file DIZZY.DAT "$OUT/DIZZY.DAT" \
    --type 2 --file DIZZY.BIN "$T/DIZZY.BIN" > /dev/null
xroar -ui null -machine coco2bus -rompath source/roms -bas BASIC.ROM -extbas EXTBASIC.ROM \
      -cart rsdos -cart-type rsdos -cart-rom DSKBASIC.ROM -load-fd0 "$T/timing.dsk" -no-disk-write-back \
      -no-ratelimit -tape-write "$T/t.wav" -tape-ao-rate 44100 -timeout 45 \
      -type 'LOADM"DIZZY":EXEC\r' > "$T/xroar.log" 2>&1 || true
python3 - "$T/t.wav" <<'PY'
import struct, sys, wave
w = wave.open(sys.argv[1], "rb"); n, rate, width = w.getnframes(), w.getframerate(), w.getsampwidth()
vals = struct.unpack("<" + {1: "B", 2: "h"}[width] * (n * w.getnchannels()), w.readframes(n))[::w.getnchannels()]
mid = (max(vals) + min(vals)) / 2
edges = [i for i in range(1, len(vals)) if (vals[i - 1] > mid) != (vals[i] > mid)]
g = []
for e in edges:
    if g and e - g[-1][1] < 0.05 * rate: g[-1][1] = e
    else: g.append([e, e])
# groups: [0] = start marker, [1] = end marker, [2] = the title music (dense edges) -- its first edge is "title playing"
if len(g) < 3: sys.exit(f"FAIL: expected start marker, end marker and music, found {len(g)} edge groups")
load = (g[1][0] - g[0][1]) / rate
title = (g[2][0] - g[1][1]) / rate
print(f"FLOPPY_TIMING XRoar, emulated seconds (tape-recording clock, production loader + drive hand-over):")
print(f"   boot loader (DIZZY.DAT, 168 sectors, incl. spin-up + restore) .......... {load:5.2f} s")
print(f"   loader hand-off -> title music audible (start: relocator + show_title:") 
print(f"      title overlay read + unpack + transpose) ............................ {title:5.2f} s")
print(f"   => from the end of Disk BASIC's LOADM to the title music ............... {load + title:5.2f} s")
PY
