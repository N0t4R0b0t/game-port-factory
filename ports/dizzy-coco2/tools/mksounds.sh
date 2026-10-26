#!/usr/bin/env bash
# Regenerate target/sound_data.asm from the original Spectrum music.
#
# The whole audio pipeline in one place: capture from the ORIGINAL
# player code running in an isolated Z80 sandbox, reduce to CoCo2 DAC
# note tables, concatenate. Re-run after changing any capture or
# reduction parameter, then rebuild with tools/stage_pack.sh.
#
# SOURCES
#   MUSIC128.SPC (aycapture)   -- the 128K AY player. THREE channels.
#   MUSIC48.SPC  (beepcapture) -- the 48K beeper player. ONE channel.
#
# Everything uses the AY capture. The 48K beeper title was tried and
# REJECTED ("sounds nothing like the original") for a reason worth
# keeping: the real game, loaded from the user's own tape in MAME on the
# 48K driver, plays NO music on its title screen at all -- 70s of digital
# silence with the cassette stopped, while the same driver did record
# beeper output from a running game (not walking sfx: that control held a
# non-game key). X-ALL.TXT gates starttune behind check128 and
# has the MUSIC48.SPC include commented out. The title tune a player
# remembers is the 128K one. beepcapture still works, and its capture is
# kept (TITLE_SRC=beep) as a reproducible alternative, not the default.
#
# The AY title keeps its melody channel only (the CoCo has one blocking
# DAC), but with the melody's VOLUME ENVELOPE: vol_step=1 follows every
# level change, which was the difference between "recognisable but
# terrible" and a tune. See pt_step in room36.asm.
#
# reduce's parameters, in the order they appear:
#   bucket_divisor         larger = finer pitch quantisation
#   max_ms                 total blocking-time cap (a backstop)
#   max_halfwaves_per_run  per-note shortener, KEEPS the whole contour
#   vol_step               split a held note when its amplitude moves this
#                          much (1 = follow the envelope, 16 = never)
#
# The caps matter because play_tone BLOCKS the mainloop. Anything that
# can fire during active gameplay has to fit the ~20ms of spare frame
# time (NOTES.md: room36 spends ~47ms of 66.7ms drawing). The title
# tune is exempt -- it plays in its own wait loop with nothing else to
# do -- which is why it alone is uncapped.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=research/D3-prior-art/original_source
C=tools/aycapture/captures
mkdir -p "$C"   # captures/ is gitignored (user-derived); a fresh clone has no such dir
BIN=tools/aycapture/target/release
OUT=target/sound_data.asm
TITLE_SRC=${TITLE_SRC:-ay}

cargo build --release --manifest-path tools/aycapture/Cargo.toml >/dev/null

# --- capture -------------------------------------------------------
$BIN/aycapture $SRC/MUSIC128.SPC tune 0  1000 $C/tune0.csv
$BIN/aycapture $SRC/MUSIC128.SPC tune 1  1000 $C/tune1.csv
$BIN/aycapture $SRC/MUSIC128.SPC tune 5  1000 $C/tune5.csv
$BIN/aycapture $SRC/MUSIC128.SPC fx   0   150 $C/fx0.csv   # T0260: the walking thud (X-ALL updatedizzy: sndfx 0 on animation frames 1/5)
$BIN/aycapture $SRC/MUSIC128.SPC fx   1   150 $C/fx1.csv
$BIN/aycapture $SRC/MUSIC128.SPC fx   21  150 $C/fx21.csv
# T0109: the rest of the trigger table.
$BIN/aycapture $SRC/MUSIC128.SPC tune 2  1000 $C/tune2.csv
# T0221: tune3 (completion tune), ONE full loop = 1311 frames (it loops; autocorrelation
# peak). Feeds tools/stage_pack.sh's TAPE_ROOMS=1 mixer blob (target/win_mix3.asm), NOT
# sound_data.asm.
$BIN/aycapture $SRC/MUSIC128.SPC tune 3  1311 $C/tune3_win.csv
$BIN/aycapture $SRC/MUSIC128.SPC fx   6   150 $C/fx6.csv
$BIN/aycapture $SRC/MUSIC128.SPC fx   11  150 $C/fx11.csv
$BIN/aycapture $SRC/MUSIC128.SPC fx   25  150 $C/fx25.csv
# T0111: the dragon's breath -- pure AY noise, reduced to noise entries.
$BIN/aycapture $SRC/MUSIC128.SPC fx   10  150 $C/fx10.csv
# 3-voice title stream for TITLE_MIX3 builds (target/title_mix3.asm):
# semitone-quantised (617 bytes packed), at the mixer's MEASURED sample rate.
$BIN/mix3stream $C/tune0.csv 1000 8529 $C/mix3_stream.asm --semitone
# 48K beeper title, alternative only. 769 frames = 15.4s, where the
# tune's self-similarity peaks.
$BIN/beepcapture $SRC/MUSIC48.SPC 0 769 $C/beep_tune0.csv

# --- reduce --------------------------------------------------------
#                                    label  out                 div  max_ms  max_hw  vol_step
if [ "$TITLE_SRC" = beep ]; then
  $BIN/reduce $C/beep_tune0.csv 769  tune0  $C/tune0_title.asm   24   60000  100000   16
else
  $BIN/reduce $C/tune0.csv     1000  tune0  $C/tune0_title.asm   24   60000  100000    1
fi
$BIN/reduce $C/tune1.csv      1000   tune1  $C/tune1.asm         24     600  100000    1
$BIN/reduce $C/tune5.csv      1000   tune5  $C/tune5.asm         24     120       4   16
$BIN/reduce $C/fx1.csv         150   fx1    $C/fx1.asm           24       8       2   16
# T0260: sndfx 0, a 54Hz thud: ONE captured frame = one full cycle (2 half-waves, ~19ms uncapped, which cost one mainloop
# pass in 13 while walking, see NOTES T0260); capped to ONE half-wave (~9ms) like the other action sfx.
$BIN/reduce $C/fx0.csv         150   fx0    $C/fx0.asm           24      60       1   16
$BIN/reduce $C/fx21.csv        150   fx21   $C/fx21.asm          24      60       3   16
# death tune plays while the death box waits for SPACE -- a pause, so it
# can be long; the three sfx all fire mid-action and stay short.
$BIN/reduce $C/tune2.csv      1000   tune2  $C/tune2.asm         24    1500  100000    1
$BIN/reduce $C/fx6.csv         150   fx6    $C/fx6.asm           24      60       4   16
$BIN/reduce $C/fx11.csv        150   fx11   $C/fx11.asm          24      20       2   16
$BIN/reduce $C/fx25.csv        150   fx25   $C/fx25.asm          24      60       4   16
# The breath fires mid-gameplay in room 54, so it gets the same kind of cap
# as the other action sfx: steps per run shortened (keeps the whole swell)
# with a total backstop.
$BIN/reduce $C/fx10.csv        150   fx10   $C/fx10.asm          24      30      12    3

# --- assemble ------------------------------------------------------
{
  echo "; AUTO-GENERATED by tools/mksounds.sh -- DO NOT EDIT."
  echo "; Real captured note tables from the original Spectrum music."
  echo ";   tune0 (title)     <- $([ "$TITLE_SRC" = beep ] && echo 'MUSIC48.SPC, 48K beeper' || echo 'MUSIC128.SPC, 128K AY melody + envelope')"
  echo ";   tune1 (new life)  <- MUSIC128.SPC, 128K AY"
  echo ";   tune5 (pickup)    <- MUSIC128.SPC, 128K AY"
  echo ";   fx0   (thud)      <- MUSIC128.SPC, 128K AY (T0260)"
  echo ";   fx1   (footstep)  <- MUSIC128.SPC, 128K AY"
  echo ";   fx21  (jump)      <- MUSIC128.SPC, 128K AY"
  echo ";   tune2 (death)     <- MUSIC128.SPC, 128K AY"
  echo ";   fx6   (box open)  <- MUSIC128.SPC, 128K AY"
  echo ";   fx11  (drop)      <- MUSIC128.SPC, 128K AY"
  echo ";   fx25  (killed)    <- MUSIC128.SPC, 128K AY (tone part; noise not ported)"
  echo ";   fx10  (breath)    <- MUSIC128.SPC, 128K AY noise -> noise entries"
  echo "; Format: (word:fdb, count:fcb). word \$0000 ends the table; \$FFFF is"
  echo "; a REST (count in ~1ms units); otherwise top nibble = amplitude"
  echo "; index, low 12 bits = period, count = half-waves. See pt_step."
  echo "; A period field of \$0Fxx is NOISE: xx = step delay, count = LFSR steps."
  echo
  # a TITLE_MIX3 build plays target/title_mix3.asm instead, so it does
  # not carry the single-voice title table
  echo "        ifeq TITLE_MIX3"
  cat "$C/tune0_title.asm"
  echo "        endif"
  echo
  for f in tune1 tune5 fx0 fx1 fx21 tune2 fx6 fx11 fx25 fx10; do cat "$C/$f.asm"; echo; done
} > $OUT

echo
echo "wrote $OUT ($(grep -c 'fdb' $OUT) entries)"
