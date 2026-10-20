#!/usr/bin/env bash
# T0241 -- run MAME's coco2b with the CoCo FDC cartridge and target/dizzy.dsk in drive 1 (flop1 = DRIVE 0).
#
#   tools/mame_floppy.sh [mame args...]       e.g.  -autoboot_script harness/floppy_overlays.lua
#
# MAME's coco_fdc device needs disk11.rom (Disk Extended BASIC 1.1, CRC 0b9c5415).  It is NOT in
# ~/.mame/roms, but source/roms/DSKBASIC.ROM is exactly that file, so this script copies it into a
# private rompath (target/mamerom, gitignored) -- nothing is downloaded or installed, ~/.mame is
# untouched.  Exit 3 if source/roms/DSKBASIC.ROM has a different CRC.
# DSK=path overrides the disk image; a private COPY is used when COPY=1 (so writes never touch the
# built image: the quick-save test writes to its own copy).
set -euo pipefail
cd "$(dirname "$0")/.."
ROM=source/roms/DSKBASIC.ROM
MR=target/mamerom
if [ ! -f "$MR/coco_fdc/disk11.rom" ] || ! cmp -s "$ROM" "$MR/coco_fdc/disk11.rom"; then
    crc=$(python3 -c "import zlib,sys;print('%08x'%zlib.crc32(open('$ROM','rb').read()))")
    [ "$crc" = "0b9c5415" ] || { echo "mame_floppy.sh: $ROM has CRC $crc, MAME wants 0b9c5415 (disk11.rom)" >&2; exit 3; }
    mkdir -p "$MR/coco_fdc" "$MR/coco2b"
    cp "$ROM" "$MR/coco_fdc/disk11.rom"; cp "$ROM" "$MR/coco2b/disk11.rom"
fi
DSKF=${DSK:-target/dizzy.dsk}
if [ "${COPY:-0}" = 1 ]; then
    tmp=$(mktemp /tmp/dizzy_XXXXXX.dsk); cp "$DSKF" "$tmp"; DSKF=$tmp
    # KEEP_DSK=path : copy the (possibly written) private disk there when MAME exits (T0242: inspect what a save wrote)
    trap '[ -n "${KEEP_DSK:-}" ] && cp "$tmp" "$KEEP_DSK"; rm -f "$tmp"' EXIT
    export FLOPPY_DSK_COPY=$tmp
fi
if [ "${NODISK:-0}" = 1 ]; then          # the FDC cartridge with an EMPTY drive (T0242: "no disk" must not hang the game)
    mame coco2b -rompath "$HOME/.mame/roms;$PWD/$MR" -ext fdc "$@"; exit $?
fi
if [ "${KEEP_DSK:-}" != "" ] || [ "${COPY:-0}" = 1 ]; then
    mame coco2b -rompath "$HOME/.mame/roms;$PWD/$MR" -ext fdc -flop1 "$DSKF" "$@"; exit $?
fi
exec mame coco2b -rompath "$HOME/.mame/roms;$PWD/$MR" -ext fdc -flop1 "$DSKF" "$@"
