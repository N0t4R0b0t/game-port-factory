; target/tape_heart_code.asm -- T0228 (split out of tape_daisy_code.asm by T0241, text and bytes
; UNCHANGED in the tape build): the heart demo, `theheartdemo` of X-ALL.TXT.
;
; Tape build: included in place by tape_daisy_code.asm (-DHEART_OVL/HEART_RES undefined = everything).
; FLOPPY build: the resident part is ONLY hd_random + hd_dir/hd_seed (HEART_RES defined before the include); the rest is NOT resident -- this file is
; assembled STANDALONE by tools/floppy_pack.sh with -DHEART_OVL=1 (hd_random, hd_dir and hd_seed stay
; resident: hd_random is shared with the Dylan/Doug talk code, hd_dir/hd_seed are state that must
; outlive a demo) at the two possible HIDDEN-framebuffer addresses (BUFA+TW_OFF / BUFB+TW_OFF; which
; one is hidden depends on cur_buf, so there are two blobs, OVL_HEART_A / OVL_HEART_B), against the
; resident symbol table of the final room36_floppy.map.  Entry = the first byte (tape_heart_demo).
; tape_heart_stub (floppy_code.asm) loads the right blob over the completion-tune blob and calls it.
        ifndef HEART_RES
; ---------------------------------------------------------------------
; theheartdemo (X:3517). Clobbers everything.
; ---------------------------------------------------------------------
tape_heart_demo
        jsr hd_room3
        lda >tw_base              ; the mixer blob's page (hidden buffer + TW_OFF)
        adda #(HD_PAGE_OFF-TW_OFF)/256
        tfr a,dp                  ; DP = the demo's page from here on
        com >hd_dir               ; resethearts: the add/sub patch flips every demo
        ldb #HD_TAB_OFF&255
        tfr d,x
        stx <hd_tab
        lda #32
        sta <hd_cnt
        clra
hd_rs
        pshs a                    ; resetheartslp: age, random path, first draw
        sta ,x
        jsr hd_random
        sta 1,x
        jsr hd_print
        leax 2,x
        puls a
        adda #8
        dec <hd_cnt
        bne hd_rs
        lda #255                  ; ld b,255 / allhearts
        sta <hd_n
hd_all
        ldx <hd_tab
        lda #32
        sta <hd_cnt
hd_up
        jsr hd_print              ; updateheartslp: erase, age += 4, draw
        lda ,x
        adda #4
        sta ,x
        jsr hd_print
        leax 2,x
        dec <hd_cnt
        bne hd_up
        dec <hd_n
        bne hd_all
        clra
        tfr a,dp                  ; the game assumes DP 0
        rts

; roomsetup for room 3, drawn on the LIVE page (DP 0 here): clearplayarea (bytes 1..30 of
; rows 48..183), drawfullroom (extracted/rooms.json room 3: frame 35 at (128,103),
; frame 37 at (104,103)) and printroomname. Room 3 has no name of its own: X-ALL.TXT's
; label `room3` falls through to `room22`'s string, ":THE:MARKET:SQUARE::", so the banner
; is drawn by draw_ui with cur_room briefly 22 (it repaints lives/coins as they were).
hd_room3
        clr fb_flip
        ldd #BUFA
        tst cur_buf
        beq hr_live
        ldd #BUFB
hr_live
        std draw_base
        ldx draw_base
        leax HD_WIN_TOP*32+1,x
        ldy #HD_WIN_BOT-HD_WIN_TOP
        ldu #0
hr_row
        ldb #15
hr_col
        stu ,x++
        decb
        bne hr_col
        leax 2,x
        leay -1,y
        bne hr_row
        ldx #hr_tab
hr_pl
        ldu ,x++
        stu blit_ptr
        lda ,x+
        sta blit_x
        lda ,x+
        sta blit_y
        pshs x
        jsr blit
        puls x
        cmpx #hr_tab_end
        bne hr_pl
        lda cur_room
        pshs a
        lda #22
        sta cur_room
        jsr draw_ui
        puls a
        sta cur_room
        clr fb_flip               ; draw_ui re-latches it from `upsidedown`
        rts
hr_tab
        fdb aspr_35_w
        fcb 128,103
        fdb aspr_37_w
        fcb 104,103
hr_tab_end

        endif
        ifndef HEART_OVL
; X-ALL.TXT `random` (5128), exact: s0 = (s0 - 1) ^ s1 rotated left, s2 rotated right
; through that carry, s1 = (~a rotated left through the rr carry) ^ 48 ^ s1; result
; ^ s2. (The 6809 EORA leaves C alone where the Z80 XOR clears it: asla supplies the
; zero carry-in the Z80's `rla` had.) Preserves X.
hd_random
        lda >hd_seed
        deca
        eora >hd_seed+1
        asla
        ror >hd_seed+2
        sta >hd_seed
        eora #$ff                 ; cpl (COMA would set C)
        rola
        eora #48
        eora >hd_seed+1
        sta >hd_seed+1
        eora >hd_seed+2
        rts

        endif

        ifndef HEART_RES
; getvalue (X:3665). A = phase 0..127, X = table entry -> A = signed value, preserves X.
; getsincos folded: s = phase >> 1 (0..63); quadrants 2,3 = -(quadrants 0,1); quadrant
; 1 mirrors quadrant 0 around its 17th entry (64), so hd_sin holds 17 values.
hd_getvalue
        lsra
        tfr a,b
        andb #31
        cmpb #16
        bls hg_j
        negb
        addb #32
hg_j
        ldu #hd_sin
        ldb b,u                   ; |sin| (0..64)
        pshs a                    ; s, for the sign
        lda ,x                    ; age
        mul                       ; D = age * |sin| (X:3694 `multiply`)
        ldb ,s+
        bitb #32
        beq hg_ret
        nega
hg_ret
        rts

; printheart (X:3643). X = table entry (age, path), preserved. DP = the demo's page.
hd_print
        pshs x
        bsr hp_body
        puls x,pc
hp_rts
        rts
hp_body
        lda ,x
        lsra
        lsra
        lsra
        lsra
        lsra
        anda #3
        beq hp_rts                ; age bits 5-6 clear: not drawn
        sta <hd_size
        lda 1,x
        tst >hd_dir
        bne hp_add
        suba ,x                   ; path - age
        bra hp_ph
hp_add
        adda ,x                   ; path + age
hp_ph
        anda #127
        sta <hd_ph
        bsr hd_getvalue
        adda #62
        sta <hd_x                 ; frmx (8-bit wrap as the Z80)
        lda <hd_ph
        adda #32
        anda #127
        bsr hd_getvalue
        sta <hd_t
        asla
        adda <hd_t                ; 3 * v
        adda #110
        sta <hd_y                 ; frmy
        ; ---- frame(): x outside units 31..93 draws nothing (window is 34..93)
        lda <hd_x
        cmpa #94
        bhs hp_rts
        cmpa #31
        blo hp_rts
        ldb <hd_size
        aslb
        ldu #hd_spr-2
        ldu b,u                   ; U = this size's sprite header (w,h,bpr, bitmap)
        lda 1,u
        sta <hd_rows              ; height
        leau 3,u
        ; ---- clip mask over the sprite's 16 pixels (4 nibbles = 4 units)
        ldd #$ffff
        std <hd_mask
        lda #34
        suba <hd_x
        bls hp_nol                ; x >= 34: nothing off the left
        asla
        ldx #hd_lm-2
        ldd a,x
        std <hd_mask
hp_nol
        lda <hd_x
        suba #90
        bls hp_nor                ; x <= 90: nothing off the right
        asla
        ldx #hd_rm-2
        ldd a,x
        anda <hd_mask
        andb <hd_mask+1
        std <hd_mask
hp_nor
        ; ---- three destination bytes per row from byte b = (x>>1) - 17 + (x odd);
        ; x odd: sprite 4 px into its byte pair, bytes b..b+2 get s>>4 / s<<4 (K=16);
        ; x even: bytes b+1,b+2 get s (K=1, the hi parts are 0). b may be -1 (XOR 0).
        lda <hd_x
        lsra
        ldb #1
        bcc hp_ev
        ldb #16
        inca
hp_ev
        stb <hd_k
        suba #17
        sta <hd_t
        ldb <hd_y
        lda #32
        mul
        addd >draw_base
        tfr d,x
        ldb <hd_t
        leax b,x
hp_row
        lda <hd_y
        cmpa #HD_WIN_TOP
        blo hp_nxt                ; above the window: skip the row
        cmpa #HD_WIN_BOT
        bhs hp_rts2               ; at/below the window's bottom: done
        ldd ,u
        anda <hd_mask
        andb <hd_mask+1
        stb <hd_t                 ; s1
        ldb <hd_k
        mul                       ; s0 * K: A = s0 >> 4, B = s0 << 4 (K=16) / A = 0, B = s0
        eora ,x
        sta ,x
        stb <hd_c2
        lda <hd_t
        ldb <hd_k
        mul                       ; s1 * K
        ora <hd_c2
        eora 1,x
        sta 1,x
        eorb 2,x
        stb 2,x
hp_nxt
        leau 2,u
        leax 32,x
        inc <hd_y
        dec <hd_rows
        bne hp_row
hp_rts2
        rts

hd_sin  fcb 0,6,12,18,24,30,35,40,45,49,53,56,59,61,62,63,64     ; sincostable quad 0 (+64)
hd_lm   fdb $0fff,$00ff,$000f                                     ; mask for 1..3 units off the left
hd_rm   fdb $fff0,$ff00,$f000                                     ; mask for 1..3 units off the right
hd_spr  fdb aspr_29_w,aspr_30_w,aspr_31_w                          ; frames 29/30/31 (heights 6/10/14)

        endif
        ifndef HEART_OVL
; persistent state: hd_dir lasts the whole tape session (the original's self-modified
; add/sub opcode is never reset), hd_seed too (`seed hex 59a313`).
hd_dir  fcb 0
hd_seed fcb $59,$a3,$13
        endif
