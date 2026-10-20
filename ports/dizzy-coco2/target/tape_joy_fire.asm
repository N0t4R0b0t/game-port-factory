; T0240: joy_fire (see tape_joy_code.asm), in TAPE_LOW_REGION2.
; joy_fire: end of scankeys (A, B free).  joy_f = either button down.
joy_fire
        lda #$ff
        sta $ff02              ; all columns released: bits 0/1 = buttons only
        lda $ff00
        coma
        anda #3
        sta joy_f
        beq jf_ret
        lda keyflags
        ora #16                ; SPACE
        sta keyflags
jf_ret  rts

