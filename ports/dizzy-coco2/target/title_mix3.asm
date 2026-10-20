; target/title_mix3.asm -- the title tune as the original's full THREE-voice
; AY arrangement (melody + bass + harmony), for TITLE_MIX3=1 builds only.
;
; The in-game form of harness/mixer3.asm (see its header for the mixer
; itself and for how SR=8529Hz / SPT=171 were MEASURED). Differences:
;
; * Assembled SEPARATELY (lwasm --format=raw, by tools/stage_pack.sh) and
;   POSITION-INDEPENDENT, so it does not depend on IMAGE_END, which moves
;   whenever a room changes. tools/roompack mktitle packs it and appends it
;   after the title image's packed stream, into the same load-time holes;
;   boot unpacks it into TITLE_RAW_BUF (T0146: while the gathered stream is
;   still intact, before the transpose overwrites it -- not "once the image
;   has been blitted" any more) and JSRs to its first byte.
; * Variables are DIRECT-PAGE OFFSETS: the caller picks the page (MIX3_DP,
;   inside the dead TITLE_RAW_BUF, past this blob) and loads it into DP.
;   The two places that need an absolute address -- the stream start and
;   the amplitude table -- are computed at entry (PC-relative / from DP).
; * Returns when SPACE is pressed (checked once per 50Hz tick record, with
;   the same PIA0 column-7 probe scankeys uses), with the DAC parked low.
;   Boot's existing ti_release then waits for the key to come back up.

        setdp 0
; Samples per 50Hz tick. 8529/50 = 171 is the sample-loop rate alone, but
; each tick also pays for the event routine: at 171 the in-game loop timed
; 20.38s against the stream's 20.05s (1.6% slow; the WAV drifted by the
; same ratio against a Python simulation of the stream). 168 puts the
; per-tick cost back. Only tempo changes; the pitches come from the
; per-sample rate, which is unchanged.
        ifndef SPT
SPT     equ 168
        endif

phA     equ $00
incA    equ $02
phB     equ $04
incB    equ $06
phC     equ $08
incC    equ $0a
idx     equ $0c
tick    equ $0d
sptr    equ $0f
ampA    equ $11
ampB    equ $12
ampC    equ $13
mask    equ $14
sstart  equ $15
tabp    equ $17
sumtab  equ $19             ; 8 entries, to $20
VARS_LEN equ $22

        org 0
entry
        tfr dp,a
        clrb
        tfr d,x                  ; X = start of the variables page
        ldb #VARS_LEN
clrlp   clr ,x+
        decb
        bne clrlp
        tfr dp,a
        ldb #sumtab
        tfr d,x
        stx <tabp                ; absolute address of the amplitude table
        leau stream,pcr
        stu <sstart
        stu <sptr
        ldd #1
        std <tick                ; first sample reads the first record

mix
        ldd <phA
        addd <incA
        std <phA
        lsla
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
        bcc mix
        clra                     ; SPACE: park the DAC low and hand back
        sta $ff20
        rts

event
        lda #%01111111           ; PIA0 column 7 = SPACE (as in scankeys)
        sta $ff02
        lda $ff00
        anda #%00001000
        bne ev_nokey
        orcc #1                  ; C=1: stop
        rts
ev_nokey
        ldu <sptr
        lda ,u+                  ; delay ticks until the next record
        bne ev_have
        ldu <sstart              ; end of stream: loop the tune
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
        ldx <tabp                ; bit2 = A, bit1 = B, bit0 = C (rol order)
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
        ldx <tabp
        andcc #$fe               ; C=0: keep playing
        rts

        include "mix3_stream.asm"   ; defines `stream`; tools/mksounds.sh
