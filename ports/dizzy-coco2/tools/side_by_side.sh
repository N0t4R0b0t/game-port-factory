#!/usr/bin/env bash
# T0233: compose the side-by-side video of the CoCo port (left) and the ZX Spectrum original (right), kept in step per SEGMENT.
#
#   tools/side_by_side.sh [--coco-avi A] [--coco-log L] [--zx-avi A] [--zx-log L] [--out OUT.mp4] [--jobs N] [--keep-clips] [--only K1,K2,..]
#
# Inputs (defaults are what the two recorders write):
#   CoCo : tools/playthrough.sh --no-build --raw target/pt_tmp/coco_raw.avi     (log: PT_LOG=target/pt_tmp/coco.log)
#   ZX   : tools/zx_playthrough.sh --record target/pt_tmp/zx_raw.avi            (log: PT_LOG=target/pt_tmp/zx.log)
# Both bots print `SEGSTART n t=<emulated machine seconds> ... pair=<port segment|none>`, `REC0 t=` (ZX: the AVI's first frame; the CoCo AVI starts at 0),
# `WIN t=`, `TITLE t=` and `END t=`.  Video time = machine time - REC0.
#
# T0237: since T0235 (the lair dragon needs the golden egg of room 93) the CoCo bot plays the SAME 106-segment plan as the ZX bot (R.override.coco.plan =
# R.override.zx.plan in harness/playthrough_route.lua), so segment k of one log is segment k of the other and every segment is paired by index (the `pair=` field
# of the logs is the PORT segment number the plan entry reuses, or none: it is no longer needed to find the CoCo clip).  Per segment: both clips are cut at the segment boundaries, the shorter side is held on its last frame (tpad clone), and the pair
# lasts max(duration CoCo, duration ZX).  Halves: CoCo scaled to 592 px high, ZX x2 (704x592), nearest neighbour; a label bar on top, the segment caption below.
# Audio: the CoCo's track on both channels (silence-padded to the segment length).  The ZX track is NOT mixed in: the original runs here as a 48K `spectrum`, but the
# game plays ALL its sound through the 128K AY (ifmem128 = 1, `ramon`/AY registers), so the ZX AVI's audio is digital silence (measured: -91 dB over the whole run;
# the tape-loading noise, which is beeper, does record).  Playing it on `spectrum128` would give music but changes the machine the whole bot was verified on.
# Raw AVIs are read, never modified; clips go to target/pt_tmp/sbs_clips (deleted at the end unless --keep-clips).
set -euo pipefail
cd "$(dirname "$0")/.."
COCO_AVI=target/pt_tmp/coco_raw.avi; COCO_LOG=target/pt_tmp/coco.log
ZX_AVI=target/pt_tmp/zx_raw.avi;     ZX_LOG=target/pt_tmp/zx.log
OUT=target/dizzy-side-by-side.mp4; JOBS=3; KEEP=0; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --coco-avi) COCO_AVI=$2; shift 2;; --coco-log) COCO_LOG=$2; shift 2;;
    --zx-avi) ZX_AVI=$2; shift 2;;     --zx-log) ZX_LOG=$2; shift 2;;
    --out) OUT=$2; shift 2;; --jobs) JOBS=$2; shift 2;; --keep-clips) KEEP=1; shift;; --only) ONLY=$2; shift 2;;
    *) echo "unknown arg $1" >&2; exit 2;;
  esac
done
for f in "$COCO_AVI" "$COCO_LOG" "$ZX_AVI" "$ZX_LOG"; do [ -f "$f" ] || { echo "missing $f" >&2; exit 2; }; done
FONT=/usr/share/fonts/noto/NotoSans-Bold.ttf; [ -f "$FONT" ] || FONT=/usr/share/fonts/TTF/DejaVuSans-Bold.ttf
CLIPS=target/pt_tmp/sbs_clips; rm -rf "$CLIPS"; mkdir -p "$CLIPS"

# ---- timelines.  ZX: k start end pair name ; CoCo: i start end name   (video seconds)
parse() {  # $1 = log, $2 = side (coco|zx)
  awk -v side="$2" '
    /^REC0 t=/ { split($2, a, "="); rec0 = a[2] + 0 }
    /^== SEGMENT / { n = $3; sub(":", "", n); name[n] = substr($0, index($0, ":") + 2) }
    /^SEGSTART / { n = $2; split($3, a, "="); st[n] = a[2] + 0; p = "none"; for (i = 4; i <= NF; i++) if ($i ~ /^pair=/) { split($i, b, "="); p = b[2] }; pair[n] = p; if (n + 0 > mx) mx = n + 0 }
    /^END t=/ { split($2, a, "="); endt = a[2] + 0 }
    END {
      for (n = 1; n <= mx; n++) {
        e = (n < mx) ? st[n + 1] : endt
        printf "%d\t%.3f\t%.3f\t%s\t%s\n", n, st[n] - rec0, e - rec0, pair[n], name[n]
      }
    }' "$1"
}
parse "$COCO_LOG" coco > "$CLIPS/coco.tsv"
parse "$ZX_LOG" zx > "$CLIPS/zx.tsv"
NC=$(wc -l < "$CLIPS/coco.tsv"); NZ=$(wc -l < "$CLIPS/zx.tsv")
echo "CoCo segments: $NC   ZX segments: $NZ"

# ---- one clip per ZX segment
CW=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$COCO_AVI")
CH=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$COCO_AVI")
CWS=790      # the CoCo AVI (372x240) has non-square pixels: the picture is 4:3, so 592 px high = 789.3 wide -> 790 (even)
echo "CoCo AVI ${CW}x${CH} -> ${CWS}x592 (4:3) ; ZX 352x296 -> 704x592 (x2) ; total width $((CWS + 704))"
: > "$CLIPS/cmds.txt"; rm -f "$CLIPS"/plan.tsv
prev_ce=""
while IFS=$'\t' read -r k zs ze pair zname; do
  if [ -n "$ONLY" ] && ! echo ",$ONLY," | grep -q ",$k,"; then continue; fi
  zd=$(awk -v a="$zs" -v b="$ze" 'BEGIN{printf "%.3f", b-a}')
  pair=$k      # T0237: both bots play the SAME 106-segment plan now (T0235): segment k on the left is segment k on the right
  if [ "$pair" != "none" ]; then
    cs=$(awk -F'\t' -v p="$pair" '$1==p {print $2}' "$CLIPS/coco.tsv"); ce=$(awk -F'\t' -v p="$pair" '$1==p {print $3}' "$CLIPS/coco.tsv")
    cname=$(awk -F'\t' -v p="$pair" '$1==p {print $5}' "$CLIPS/coco.tsv")
    cd=$(awk -v a="$cs" -v b="$ce" 'BEGIN{printf "%.3f", b-a}'); cfreeze=0; prev_ce=$ce
    cap="Segment $k: $cname"
  else
    # ZX-only segment: the CoCo shows its last frame frozen (the end of the last CoCo clip used)
    cs=$(awk -v a="${prev_ce:-0}" 'BEGIN{printf "%.3f", a-0.05}'); cd=0.050; cfreeze=1
    cap="ZX segment $k (ZX only, CoCo waits): $zname"
  fi
  D=$(awk -v a="$cd" -v b="$zd" 'BEGIN{printf "%.3f", (a>b)?a:b}')
  cpad=$(awk -v d="$D" -v a="$cd" 'BEGIN{printf "%.3f", d-a}'); zpad=$(awk -v d="$D" -v a="$zd" 'BEGIN{printf "%.3f", d-a}')
  printf '%s' "${cap:0:140}" > "$CLIPS/cap_$k.txt"
  cvol=1; [ $cfreeze = 1 ] && cvol=0
  printf 'ffmpeg -nostdin -loglevel error -y -ss %s -t %s -i %q -ss %s -t %s -i %q -filter_complex "[0:v]fps=60,scale=%d:592:flags=neighbor,setsar=1,tpad=stop_mode=clone:stop_duration=%s[cv];[1:v]fps=60,scale=704:592:flags=neighbor,setsar=1,tpad=stop_mode=clone:stop_duration=%s[zv];[cv][zv]hstack=inputs=2,pad=iw:ih+84:0:44:black,drawtext=fontfile=%s:text=\x27Tandy CoCo 2 (port)\x27:fontsize=26:fontcolor=white:x=(%d-text_w)/2:y=9,drawtext=fontfile=%s:text=\x27ZX Spectrum (original, 1989)\x27:fontsize=26:fontcolor=white:x=%d+(704-text_w)/2:y=9,drawtext=fontfile=%s:textfile=%s:fontsize=19:fontcolor=0xdddddd:x=12:y=h-32[v];[0:a]aformat=channel_layouts=mono,volume=%s,apad=whole_dur=%s,atrim=duration=%s,pan=stereo|c0=c0|c1=c0[a]" -map "[v]" -map "[a]" -t %s -r 60 -c:v libx264 -preset fast -crf 18 -pix_fmt yuv420p -c:a pcm_s16le %s\n' \
    "$cs" "$cd" "$COCO_AVI" "$zs" "$zd" "$ZX_AVI" "$CWS" "$cpad" "$zpad" "$FONT" "$CWS" "$FONT" "$CWS" "$FONT" "$CLIPS/cap_$k.txt" "$cvol" "$D" "$D" "$D" "$(printf '%s/clip_%03d.mkv' "$CLIPS" "$k")" > "$CLIPS/cmd_$(printf '%03d' "$k").sh"; echo "$CLIPS/cmd_$(printf '%03d' "$k").sh" >> "$CLIPS/cmds.txt"
  printf '%s\t%s\t%s\t%s\t%s\n' "$k" "$pair" "$zd" "$cd" "$D" >> "$CLIPS/plan.tsv"
done < "$CLIPS/zx.tsv"
echo "clips: $(wc -l < "$CLIPS/cmds.txt")   expected duration (sum of max): $(awk -F'\t' '{s+=$5} END{printf "%.1f s", s}' "$CLIPS/plan.tsv")"
xargs -P "$JOBS" -n1 bash < "$CLIPS/cmds.txt"
ls "$CLIPS"/clip_*.mkv | sed "s|^|file '$PWD/|; s|\$|'|" > "$CLIPS/list.txt"
ffmpeg -nostdin -loglevel error -y -f concat -safe 0 -i "$CLIPS/list.txt" -c:v copy -c:a aac -b:a 160k "$OUT"
cp "$CLIPS/plan.tsv" "${OUT%.mp4}.plan.tsv"
[ $KEEP = 1 ] || rm -rf "$CLIPS"
ls -l "$OUT"; ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT"
