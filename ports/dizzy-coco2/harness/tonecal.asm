; T0088/T0089: standalone tone-generator CALIBRATION probe -- NOT part
; of the shipping build, and not a template for one. Feeds play_tone's
; own loop-cost model: fixed PERIOD values, each captured with MAME's
; -wavwrite and measured with harness/audiocheck.py, least-squares fit
; against those points. This is how play_tone's own header formula was
; derived -- re-run this (and refit) if play_tone's instruction
; sequence ever changes, since the fit describes THAT loop's exact
; cycle cost, not something the DAC hardware guarantees on its own.
;
; T0089 widened this to a 16-bit period (see play_tone's own header in
; room36.asm for why -- 90%+ of the real captured music sits below the
; 8-bit version's ~340Hz floor). This probe's play_tone below is kept
; byte-for-byte in sync with the shipping one for that reason.
;
;   for per in 100 150 196 250 800 1600 3000; do
;     lwasm --decb -DPERIOD=$per -DCOUNT=2000 -o /tmp/tone_$per.bin harness/tonecal.asm
;     mame coco2b -ext "" -nothrottle -video none -seconds_to_run 4 \
;       -wavwrite /tmp/tone_$per.wav -autoboot_script harness/mame_load_run.lua
;     harness/audiocheck.py /tmp/tone_$per.wav
;   done
;
; NO `--scan` ON THAT LAST LINE, EVER. This probe loops one tone forever
; precisely so the DEFAULT tail window always lands on a sustained tone,
; which is the only thing audiocheck.py measures pitch reliably for.
; T0089 added --scan here "for safety" and it read these very captures
; 25-34% low, by a frequency-DEPENDENT amount; the resulting calibration
; shipped music that was 6-40 semitones sharp with stretched intervals,
; and a playtest -- not any check in this repo -- is what caught it.
; Cross-check any fit against the hand-derived cycle counts in
; play_tone's header in room36.asm (66 + 16*period per full wave); if a
; measurement disagrees with the instruction timings by more than a few
; percent, the MEASUREMENT is what is wrong.
        org $0e00
start
        orcc #$50
        lds #$0100
        lda #$35
        sta $ff03
        sta $ffc0
        sta $ffc3
        sta $ffc5
        sta $ffc6
        sta $ffc8
        sta $ffca
        sta $ffcc
        sta $ffce
        sta $ffd1
        sta $ffd2

        ; DAC recipe (T0088, verified): PIA1 CB2 sound enable.
        lda $ff23
        ora #8
        sta $ff23

        ldx #PERIOD
        stx pt_period
loop
        ldd #COUNT
        std pt_count
        jsr play_tone
        bra loop

; play_tone: pt_period (half-wave delay, PITCH, 16-bit) and pt_count
; (number of half-waves, DURATION, 16-bit here only so this probe can
; loop a huge COUNT without reloading -- the shipping version uses an
; 8-bit count, see room36.asm) preset by the caller. Blocking square
; wave on the 6-bit DAC (bits 7-2 of $FF20).
play_tone
        clr pt_level
pt_wave
        lda pt_level
        eora pt_amp               ; T0089: per-note amplitude, see room36.asm
        sta pt_level
        sta $ff20
        ldx pt_period
pt_delaylp
        leax -1,x
        bne pt_delaylp
        ldd pt_count
        subd #1
        std pt_count
        bne pt_wave
        rts

pt_period fdb 0
pt_amp    fcb $40
pt_count  fdb 0
pt_level  fcb 0
        end start
