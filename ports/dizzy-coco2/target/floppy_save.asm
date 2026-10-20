; floppy_save.asm -- T0242: the QUICK SAVE / LOAD overlay (FLOPPY build).  Assembled STANDALONE by
; tools/floppy_pack.sh (like the heart demo) at the two hidden-framebuffer addresses BASE = BUFx+TW_OFF, against
; the final map; OVL_SAVE_A / OVL_SAVE_B on DIZZY.OVL.  Entry points (3-byte lbra table at BASE):
;     BASE+0  sv_save   write the state to DIZZY.SAV            -> A = 0 ok, 3 disk error
;     BASE+3  sv_read   read + check, nothing applied yet       -> A = 0 ok, 1 no save, 2 other build, 3 disk/damaged
;     BASE+6  sv_apply  copy the checked staging image into RAM -> A = 0
; The image is built/read in a STAGING buffer in the same (hidden) framebuffer at BASE+$A00: the game runs in
; all-RAM mode, so the ranges above $8000 (block D variables, the tape tables) are plain RAM and are copied
; byte by byte -- no ROM/bank issue; the disk driver then moves whole sectors staging <-> disk.
; Image = 16-byte header + the ranges of target/floppy/state_ranges.asm back to back (tools/floppy_state_check.py):
;     "DZSV"  build ID (4, CRC32 of room36_floppy.bin: any rebuild invalidates old saves)  STATE_LEN (2)
;     sum16 of the payload (2)  4 spare.
; Header is checked BEFORE a byte of game state is touched (sv_read), apply is a pure copy.
        include "state_ranges.asm"
STG        equ BASE+$A00
SV_SECS    equ (STATE_LEN+16+255)/256
        ifgt SV_SECS-SAV_SECS
        error "the state no longer fits DIZZY.SAV"
        endif
        ifgt SV_SECS*256-$800
        error "staging buffer does not fit the hidden framebuffer"
        endif

sv_jt   lbra sv_save            ; BASE+0: the first bytes of the overlay are the entry table
        lbra sv_read
        lbra sv_apply

sv_save
        ldx #STG                ; zero the image
        ldy #SV_SECS*256
svs_z   clr ,x+
        leay -1,y
        bne svs_z
        ldx #STG
        lda #$44                ; 'D'
        sta ,x
        lda #$5A                ; 'Z'
        sta 1,x
        lda #$53                ; 'S'
        sta 2,x
        lda #$56                ; 'V'
        sta 3,x
        ldd #BUILD_HI
        std 4,x
        ldd #BUILD_LO
        std 6,x
        ldd #STATE_LEN
        std 8,x
        ldu #STG+16
        lbsr sv_pack
        lbsr sv_sum
        std STG+10
        lda #2                  ; two tries
        sta sv_try
svs_w   lda #SAV_TRK
        sta fd_trk
        lda #SAV_SEC
        sta fd_sec
        lda #SV_SECS
        sta fd_cnt
        ldx #STG
        jsr fd_write
        tsta
        beq svs_ok
        dec sv_try
        bne svs_w
        lda #3
        rts
svs_ok  clra
        rts

sv_read
        lda #2
        sta sv_try
svr_r   lda #SAV_TRK
        sta fd_trk
        lda #SAV_SEC
        sta fd_sec
        lda #SV_SECS
        sta fd_cnt
        ldx #STG
        jsr fd_read
        tsta
        beq svr_got
        dec sv_try
        bne svr_r
        lda #3
        rts
svr_got
        ldd STG
        cmpd #$445A
        bne svr_none
        ldd STG+2
        cmpd #$5356
        bne svr_none
        ldd STG+4
        cmpd #BUILD_HI
        bne svr_ver
        ldd STG+6
        cmpd #BUILD_LO
        bne svr_ver
        ldd STG+8
        cmpd #STATE_LEN
        bne svr_ver
        lbsr sv_sum
        cmpd STG+10
        bne svr_bad
        clra
        rts
svr_none lda #1
        rts
svr_ver lda #2
        rts
svr_bad lda #3
        rts

sv_apply
        ldu #STG+16
        ldy #state_ranges
        ldb #STATE_NRANGES
sva_1   pshs b
        ldx ,y++                ; destination
        ldd ,y++                ; length
        pshs d
sva_2   lda ,u+
        sta ,x+
        ldd ,s
        subd #1
        std ,s
        bne sva_2
        leas 2,s
        puls b
        decb
        bne sva_1
        clra
        rts

; sv_pack: ranges -> U (staging)
sv_pack
        ldy #state_ranges
        ldb #STATE_NRANGES
svp_1   pshs b
        ldx ,y++                ; source
        ldd ,y++                ; length
        pshs d
svp_2   lda ,x+
        sta ,u+
        ldd ,s
        subd #1
        std ,s
        bne svp_2
        leas 2,s
        puls b
        decb
        bne svp_1
        rts

; sv_sum: D = 16-bit sum of the payload in staging
sv_sum
        ldx #STG+16
        ldy #STATE_LEN
        ldd #0
svm_1   addb ,x+
        bcc svm_2
        inca
svm_2   leay -1,y
        bne svm_1
        rts

sv_try  fcb 0
        include "state_table.asm"
sv_end
        ifgt sv_end-BASE-$A00
        error "the save overlay overruns its staging buffer"
        endif
        ifgt sv_end-BASE-OVL_SAVE_A_CAP*256
        error "the save overlay is larger than its DIZZY.OVL slot"
        endif
