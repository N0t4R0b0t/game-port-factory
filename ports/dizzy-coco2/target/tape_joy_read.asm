; T0240: joy_read + variables (see tape_joy_code.asm), in TAPE_LOW_REGION3.
; joy_read: A = right X, 0..63 (left .. right).
joy_read
        lda #$34
        sta $ff01                ; CA2 = 0 (mux select 00 = right X = the DAC's)
        lda $ff23
        pshs a
        anda #$f7
        sta $ff23                ; sound enable off while the DAC probes
        lda #2                   ; bit 1 (serial out) stays high, as JOYIN
        ldb #$80
jr_lp   stb ,-s
        ora ,s                   ; try the bit
        sta $ff20
        tst $ff00                ; comparator (bit 7) -> N
        bmi jr_keep
        eora ,s                  ; pot is below: drop the bit
jr_keep ldb ,s+
        lsrb
        cmpb #2
        bne jr_lp
        clr $ff20                ; DAC at rest (pt_rest's level)
        clr pt_level
        puls b
        stb $ff23                ; sound enable back
        lsra
        lsra
        rts

joy_f     fcb 0
joy_acc   fcb 3
joy_armed fcb 0
