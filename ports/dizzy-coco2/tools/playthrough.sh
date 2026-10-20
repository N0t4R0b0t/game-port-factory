#!/usr/bin/env bash
# T0231: play the whole tape build with keys only (harness/playthrough.lua + playthrough_route.lua).
#   tools/playthrough.sh [--floppy] [--from N] [--until N] [--watch] [--no-build] [--record OUT.mp4 | --raw OUT.avi]
# --floppy (T0241): play the FLOPPY build (target/room36_floppy.bin) in MAME with the CoCo FDC and target/dizzy.dsk
#   (a private copy, tools/mame_floppy.sh): the bot pokes the image like always, but every overlay (title replay after the
#   win, the heart demo, ...) is then read from the disk by the game itself through the emulated WD1793.
# Headless by default (-nothrottle, no video, no sound). --watch = video + sound at real speed in a MAME window.
# Exit 0 only on "PLAYTHROUGH PASS" (boot -> win -> title), or on PARTIAL when --until was given.
# PT_DEV_POKE63=1 (dev): pokes the unreachable coin 63 so the rest of the route can be tested; verdict DEVRUN, exit 1.  Checkpoints: target/pt_states/ (MAME save states pt_seg<N>).
set -uo pipefail
cd "$(dirname "$0")/.."
FROM=1; UNTIL=999; UNTIL_GIVEN=0; WATCH=0; BUILD=1; REC=""; RAW=""; FLOPPY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM=$2; shift 2;;
    --until) UNTIL=$2; UNTIL_GIVEN=1; shift 2;;
    --watch) WATCH=1; shift;;
    --no-build) BUILD=0; shift;;
    --floppy) FLOPPY=1; shift;;
    --record) REC=$2; shift 2;;
    --raw) RAW=$2; shift 2;;      # T0233: keep MAME's raw AVI at this path (the side-by-side composer cuts it; ~15 MB per emulated second) and do not encode it
    *) echo "unknown arg $1" >&2; exit 2;;
  esac
done
if [ $BUILD = 1 ] && [ $FLOPPY = 1 ]; then
  echo "== tools/floppy_pack.sh (runs the FLOPPY=1 pipeline twice itself)"
  tools/floppy_pack.sh > /tmp/playthrough_fpack.log 2>&1 || { echo "floppy_pack.sh failed (/tmp/playthrough_fpack.log)"; exit 2; }
elif [ $BUILD = 1 ]; then
  echo "== tools/tape_pack.sh (twice: hole addresses settle on the 2nd run)"
  tools/tape_pack.sh > /tmp/playthrough_pack1.log 2>&1 || { echo "tape_pack.sh run 1 failed (/tmp/playthrough_pack1.log)"; exit 2; }
  tools/tape_pack.sh > /tmp/playthrough_pack2.log 2>&1 || { echo "tape_pack.sh run 2 failed (/tmp/playthrough_pack2.log)"; exit 2; }
fi
STATED=target/pt_states; [ $FLOPPY = 1 ] && STATED=target/pt_states_floppy   # checkpoints are build-specific
mkdir -p $STATED
[ -f target/pt_masks/room36.msk ] || python3 tools/pt_dump_masks.py
export DIZZY_BIN=target/room36_tape.bin DIZZY_MAP=target/room36_tape.map
if [ $FLOPPY = 1 ]; then export DIZZY_BIN=${FLOPPY_BIN:-target/room36_floppy.bin} DIZZY_MAP=${FLOPPY_MAP:-target/room36_floppy.map}; fi
export PT_FROM=$FROM PT_UNTIL=$UNTIL PT_STATEDIR=$STATED PT_ROOT=.
[ "$WATCH" = 1 ] && export PT_WATCH=1
if [ "$WATCH" = 1 ]; then
  VID=(-window -sound auto); THR=(-throttle)
else
  VID=(-video none -sound none); THR=(-nothrottle)
fi
LOG=${PT_LOG:-/tmp/playthrough_last.log}
# --record OUT.mp4: MAME writes an uncompressed AVI (emulated time, so it is
# full length even under -nothrottle), then ffmpeg compresses it.
RECARGS=()
if [ -n "$RAW" ]; then
  mkdir -p "$(dirname "$RAW")"; RAWABS=$(realpath -m "$RAW")
  RECARGS=(-snapshot_directory "$(dirname "$RAWABS")" -aviwrite "$(basename "$RAWABS")")
  export PT_TAIL_FRAMES=${PT_TAIL_FRAMES:-400}
  VID=(-video none -sound none)
elif [ -n "$REC" ]; then
  mkdir -p target/pt_tmp; RECDIR=$(mktemp -d "$PWD/target/pt_tmp/ptrec.XXXX")   # on disk: the raw AVI is ~12 MB per emulated second
  RECARGS=(-snapshot_directory "$RECDIR" -aviwrite pt.avi)
  export PT_TAIL_FRAMES=${PT_TAIL_FRAMES:-400}   # ~7 s on the finished title
  VID=(-video none -sound none)
fi
if [ $FLOPPY = 1 ]; then MAMECMD=(env COPY=1 DSK=${FLOPPY_DSK:-target/dizzy.dsk} tools/mame_floppy.sh); else MAMECMD=(mame coco2b -ext ""); fi
timeout ${PT_TIMEOUT:-3000} "${MAMECMD[@]}" "${THR[@]}" "${VID[@]}" \
  -state_directory "$PWD/$STATED" -seconds_to_run ${PT_SECONDS:-4000} "${RECARGS[@]}" \
  -autoboot_script harness/playthrough.lua 2>&1 | grep -v 'load_dat' | tee "$LOG"
if [ -z "$RAW" ] && [ -n "$REC" ] && [ -f "$RECDIR/pt.avi" ]; then
  echo "== encoding $REC (raw AVI: $(du -h "$RECDIR/pt.avi" | cut -f1))"
  ffmpeg -loglevel error -y -i "$RECDIR/pt.avi" -c:v libx264 -preset slow -crf 18 -pix_fmt yuv420p \
    -vf "scale=768:576:flags=neighbor" -c:a aac -b:a 128k "$REC" && rm -rf "$RECDIR"
  ls -l "$REC"
fi
if grep -q '^PLAYTHROUGH PASS' "$LOG"; then exit 0; fi
if [ $UNTIL_GIVEN = 1 ] && grep -q '^PLAYTHROUGH PARTIAL' "$LOG"; then exit 0; fi
exit 1
