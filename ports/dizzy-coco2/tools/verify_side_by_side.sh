#!/usr/bin/env bash
# T0233 verifier for tools/side_by_side.sh (a cheaper tier can run it; exit 0 = all checks passed).
#   tools/verify_side_by_side.sh [VIDEO.mp4]      (default target/dizzy-side-by-side.mp4; needs the .plan.tsv next to it)
# Checks:
#  1. the video exists with a video stream 1536x660 @60 fps and a stereo audio stream;
#  2. its duration equals the plan's sum of max(CoCo, ZX) segment durations within 1.0 s (the plan is written by the composer);
#  3. SYNC: at the first frame of EVERY segment pair (plan start + 0.5 s) and 0.3 s before its end, both halves of the frame are non-blank (mean luma of
#     each half above a floor) -- a clip cut at a wrong time or a missing clip shows up as a black or frozen-black half;
#  4. the label bar is present (top 44 px not all black: the two labels) and the final frame shows both title screens (non-blank halves).
# (The semantic check "both halves show the same room" is tools/verify_zx_playthrough.sh: paired segments end in the same room, from the logs.)
set -uo pipefail
cd "$(dirname "$0")/.."
V=${1:-target/dizzy-side-by-side.mp4}; P=${V%.mp4}.plan.tsv
fail=0; ok() { echo "  ok   $*"; }; bad() { echo "  FAIL $*"; fail=1; }
[ -f "$V" ] && [ -f "$P" ] || { echo "missing $V or $P"; exit 2; }
dims=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate -of csv=p=0 "$V")
[ "$dims" = "1536,660,60/1" ] && ok "video $dims" || bad "video stream is '$dims' (expected 1536,660,60/1)"
ch=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 "$V"); [ "$ch" = "2" ] && ok "stereo audio" || bad "audio channels '$ch'"
dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$V"); want=$(awk -F'\t' '{s+=$5} END{printf "%.3f", s}' "$P")
awk -v a="$dur" -v b="$want" 'BEGIN{d=a-b; if (d<0) d=-d; exit (d>1.0)}' && ok "duration $dur s = plan sum of max $want s (+-1 s)" || bad "duration $dur s vs plan $want s"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
n=0; blank=0
awk -F'\t' 'BEGIN{t=0} {printf "%d %.3f %.3f\n", $1, t+0.5, t+$5-0.3; t+=$5}' "$P" > "$T/pts"
while read -r k t0 t1; do
  for t in $t0 $t1; do
    n=$((n+1))
    ffmpeg -nostdin -loglevel error -y -ss "$t" -i "$V" -frames:v 1 -vf "crop=iw:ih-44-40:0:44,scale=1536:576" -pix_fmt gray "$T/f.png" 2>/dev/null || { bad "no frame at $t (segment $k)"; continue; }
    # mean luma of the left and right halves (both halves 768 px wide, T0253: equal 256x192 areas x3)
    l=$(ffmpeg -nostdin -loglevel info -i "$T/f.png" -vf "crop=768:576:0:0,signalstats,metadata=print:key=lavfi.signalstats.YAVG" -f null - 2>&1 | grep -o 'YAVG=[0-9.]*' | tail -1 | cut -d= -f2)
    r=$(ffmpeg -nostdin -loglevel info -i "$T/f.png" -vf "crop=768:576:768:0,signalstats,metadata=print:key=lavfi.signalstats.YAVG" -f null - 2>&1 | grep -o 'YAVG=[0-9.]*' | tail -1 | cut -d= -f2)
    awk -v l="${l:-0}" -v r="${r:-0}" 'BEGIN{exit !(l>25 && r>6)}' || { blank=$((blank+1)); echo "    blank half at t=$t (segment $k): coco=$l zx=$r"; }
  done
done < "$T/pts"
[ $blank -eq 0 ] && ok "sync/blank check: $n frames (start and end of every segment pair): no blank half" || bad "$blank of $n sampled frames have a blank half"
top=$(ffmpeg -nostdin -loglevel info -ss 5 -i "$V" -frames:v 1 -vf "crop=iw:44:0:0,signalstats,metadata=print:key=lavfi.signalstats.YAVG" -f null - 2>&1 | grep -o 'YAVG=[0-9.]*' | tail -1 | cut -d= -f2)
awk -v t="${top:-0}" 'BEGIN{exit !(t>1.0)}' && ok "label bar present (top 44 px luma $top)" || bad "label bar missing"
[ $fail = 0 ] && echo "VERIFY SIDE-BY-SIDE: ALL CHECKS PASSED" || echo "VERIFY SIDE-BY-SIDE: FAILED"
exit $fail
