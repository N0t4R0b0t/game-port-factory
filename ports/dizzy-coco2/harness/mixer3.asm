; harness/mixer3.asm -- STANDALONE 3-voice AY mixer prototype for the
; CoCo2's 6-bit DAC. NOT part of the game build.
;
; Question it answers: does the original's full three-channel title tune
; (melody + bass + harmony) sound acceptable on this DAC? The shipping
; title plays the melody alone through play_tone. This plays all three
; voices at once so the user can hear the difference before anyone spends
; the memory-map work of fitting it into the game (NOTES.md "Title tune as
; full 3-voice AY -- feasibility numbers").
;
; HOW: three 16-bit phase accumulators, stepped once per output sample;
; each voice is the top bit of its accumulator. The three bits index an
; 8-entry table of summed amplitudes (rebuilt only when a volume changes),
; which goes straight to $FF20. Every 50Hz tick of the ORIGINAL music, the
; next record of a tools/aycapture/mix3stream event stream updates
; increments/amplitudes. Variables live on the direct page for cheaper
; loads and adds.
;
; SR (the sample rate) is not assumed from cycle counting -- a --cal stream
; plays one steady tone, audiocheck.py measures it, and SR follows from the
; increment. SPT = samples per 50Hz tick = round(SR/50).
;
; MEASURED: increment 3604 played 469.0Hz -> SR = 469*65536/3604 = 8529Hz
; (cycle counting had predicted ~8060), so SPT = 171. Tempo checked from
; INSIDE the program, not from the audio: a Lua script timestamps each wrap
; of sptr back to the stream start -- 20.41s per 1000-tick loop against
; 20.05s nominal, ~2% slow from per-record event processing; SPT=168 would
; absorb it. (Audio-envelope autocorrelation gave 17.4s and 27.2s on the
; same kind of recording -- unusable for tempo on this signal.)
;
;   cargo build --release --manifest-path tools/aycapture/Cargo.toml
;   tools/aycapture/target/release/mix3stream - 0 8000 /tmp/mix3_stream.asm --cal 440
;   lwasm --decb -DSPT=160 -I/tmp -o /tmp/mix3.bin harness/mixer3.asm
;   DIZZY_BIN=/tmp/mix3.bin mame coco2b -ext "" -nothrottle -video none \
;     -seconds_to_run 4 -wavwrite /tmp/mix3.wav -autoboot_script harness/mame_load_run.lua
;   harness/audiocheck.py /tmp/mix3.wav            # default mode, NOT --scan

        org $0e00
; Variables on page $06, BELOW the program. They first sat at $1000 --
; inside the event stream, which is assembled straight after this code
; and runs to ~$2600 for the full tune. Every variable write corrupted
; the stream and playback jumped into garbage; the 6-byte calibration
; stream never reached $1000, which is why calibration looked fine.
DPG     equ $06
        setdp DPG

phA     equ $0600
incA    equ $0602
phB     equ $0604
incB    equ $0606
phC     equ $0608
incC    equ $060a
idx     equ $060c
tick    equ $060d
sptr    equ $060f
ampA    equ $0611
ampB    equ $0612
ampC    equ $0613
mask    equ $0614
sumtab  equ $0618

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
        lda $ff23                ; DAC sound enable, PIA1 CB2 (T0088)
        ora #8
        sta $ff23

        lda #DPG
        tfr a,dp
        ldx #$0600               ; clear all mixer state
clrlp   clr ,x+
        cmpx #$0620
        bne clrlp
        ldd #stream
        std <sptr
        ldd #1
        std <tick                ; first sample runs the first record
        ldx #sumtab

mix
        ldd <phA
        addd <incA
        std <phA
        lsla                     ; top bit -> carry
        rol <idx
        ldd <phB
        addd <incB
        std <phB
        lsla
        rol <idx
        ldd <phC
        addd <incC
        std <phC
        lsla
        rol <idx
        ldb <idx
        andb #7
        lda b,x
        sta $ff20
        ldd <tick
        subd #1
        std <tick
        bne mix
        bsr event
        bra mix

event
        ldu <sptr
        lda ,u+                  ; delay ticks until the next record
        bne ev_have
        ldu #stream              ; end of stream: loop the tune
        lda ,u+
ev_have
        ldb #SPT
        mul
        std <tick
        lda ,u+
        sta <mask
        bita #$20
        beq ev_pb
        ldd ,u++
        std <incA
ev_pb   lda <mask
        bita #$10
        beq ev_pc
        ldd ,u++
        std <incB
ev_pc   lda <mask
        bita #$08
        beq ev_vol
        ldd ,u++
        std <incC
ev_vol  lda <mask
        bita #$07
        beq ev_done
        bita #$04
        beq ev_vb
        ldb ,u+
        stb <ampA
ev_vb   bita #$02
        beq ev_vc
        ldb ,u+
        stb <ampB
ev_vc   bita #$01
        beq ev_tab0
        ldb ,u+
        stb <ampC
ev_tab0
        ldx #sumtab              ; bit2 = A, bit1 = B, bit0 = C (rol order)
        clrb
ev_tab  clra
        bitb #4
        beq ev_t1
        adda <ampA
ev_t1   bitb #2
        beq ev_t2
        adda <ampB
ev_t2   bitb #1
        beq ev_t3
        adda <ampC
ev_t3   sta b,x
        incb
        cmpb #8
        bne ev_tab
ev_done
        stu <sptr
        ldx #sumtab
        rts

        include "mix3_stream.asm"
        end start
