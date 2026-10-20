; Minimal PMODE4 (6R, 256x192, 2-color) screen-setup test, entirely
; self-contained -- no BASIC PMODE/SCREEN commands relied on, since typing
; BASIC commands via xroar's -type proved unreliable in this dev sandbox.
; Sets up the VDG mode via PIA1 ($FF22) and the SAM's video-mode (V0-V2)
; and display-start-address (F0-F6) registers directly, then fills the
; framebuffer with a test pattern and hangs so the result can be inspected.
;
; Framebuffer placed at $4000 (512-byte aligned, comfortably clear of our
; own code/data and low system RAM): $4000 / 512 = 32 = %0100000, so only
; F5 needs setting, all other F bits cleared.
        org $0E00

start
        ; SAM V0-V2 = 110 (6R/6C mode family)
        lda $ffc0       ; V0 = 0
        lda $ffc3       ; V1 = 1 (set)
        lda $ffc5       ; V2 = 1 (set)

        ; SAM F0-F6 = 0100000 (buffer at $4000)
        lda $ffc6       ; F0 = 0
        lda $ffc8       ; F1 = 0
        lda $ffca       ; F2 = 0
        lda $ffcc       ; F3 = 0
        lda $ffce       ; F4 = 0
        lda $ffd1       ; F5 = 1 (set)
        lda $ffd2       ; F6 = 0

        ; PIA1 $FF22: bits7-4=$F (6R/PMODE4), bit3=1 (CSS=1, black/white),
        ; bits2-0 preserved (unrelated I/O lines)
        lda $ff22
        anda #$07
        ora #$f8
        sta $ff22

        ldy #$4000
        ldx #6144
        lda #$AA
fillp   sta ,y+
        leax -1,x
        bne fillp
hang    bra hang

        end start
