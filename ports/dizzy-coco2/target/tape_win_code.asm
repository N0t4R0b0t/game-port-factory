; target/tape_win_code.asm -- T0221: the completion tune under the win boxes.
; TAPE build only; assembled inside the TAPE_LOW_REGION slot (room36.asm).
;
; X-ALL.TXT daisyrou1 (doendmessages): `ld a,3 / call starttune` starts tune 3
; in the BACKGROUND, then `completedgame=1`, `chatter` (the gotallcoins boxes,
; each waiting for a key), then `theheartdemo`, `jp musicoff`. The port has no
; background mixer, so the tune runs INSIDE each box's wait: draw the box, run
; the title's 3-voice mixer until SPACE (its own SPACE poll IS the dismissal),
; next box. The mixer carries on where it stopped (win_resume, win_mix3.asm),
; so it is one tune across all the boxes, not a restart per box.
;
; Where the mixer lives: its LZ blob is in TAPE_LOW_REGION2 (gap1, loaded at
; boot) and is unpacked, at the win, into the HIDDEN framebuffer. msg_begin
; paints the box straight onto the live page (cur_buf==0: A is live, else B),
; and nothing flips while a chatter run is up, so the other buffer is free
; scratch and never shown. The blob is position-independent (title_mix3.asm);
; its direct-page variables take the first whole page after it, inside that
; same buffer (guards below). force_redraw afterwards (caller) repaints both.
; T0228: the blob starts at TW_OFF = 1536 into the hidden buffer, i.e. BELOW rows 0..47: the
; banner art is never repainted by redraw in the tape build (T0237), so a blob unpacked at
; the buffer's start would leave a garbage banner behind whenever the game goes on after
; the tune (Daisy's meeting in room 94; the win ends in the title, which repaints all).
TW_OFF       equ 1536
WIN_DP_PAGES equ (TW_OFF+WIN_MIX3_RAW+255)/256   ; DP page = buffer page + this
        ifgt WIN_DP_PAGES*256+256-6144
        error "completion-tune mixer blob + its DP page no longer fit one framebuffer"
        endif

; X = message stream (msg_gotallcoins). Clobbers A,B,X,Y,U.
tape_win_chatter
        pshs x
        jsr tape_win_init
        puls x
tw_box
        bsr tw_one_box
        lda ,x
        bne tw_box                ; another box follows
tw_release
        jsr fb_stablekeys         ; hold on until SPACE is up, so the title
        bita #16                  ; replay is not skipped by the same press
        bne tw_release
        rts

; T0228: the same machinery for Daisy's meeting in room 94 (tape_daisy_code.asm),
; whose boxes are separated by the (silent) heart demo. tape_win_init unpacks the
; blob and arms a fresh tune; tape_win_one = ONE box (X = a single message, no
; run terminator) with the tune under it, then waits for SPACE up. The second
; call resumes the tune where the first stopped (tw_started is set), exactly
; like the boxes of one chatter run.
tape_win_init
        ldy #BUFB+TW_OFF          ; cur_buf==0: A live -> B hidden
        lda cur_buf
        beq tw_have
        ldy #BUFA+TW_OFF          ; cur_buf==1: B live -> A hidden
tw_have
        sty tw_base
        tfr y,d                   ; A = the blob's page, B = 0 (TW_OFF is a whole number of pages)
        adda #WIN_DP_PAGES-TW_OFF/256
        sta tw_dp
        ldu #win_mix3_lz
        jsr lz_unpack             ; Y = hidden buffer
        clr tw_started
        rts
tape_win_one
        bsr tw_one_box
        bra tw_release

; One box + the tune under it. X = message; returns X just past its mend.
tw_one_box
        pshs x
        jsr msg_begin
        puls x
        jsr prtmessage            ; leaves X just past this box's mend
        pshs x
        lda #1
        sta msg_active            ; the harnesses' "a box is up" byte
        jsr tw_music
        clr msg_active
        puls x,pc

; Music until SPACE. SPACE must be released first (the previous box's press
; would stop the mixer on its first sample).
tw_music
        jsr fb_stablekeys
        bita #16
        bne tw_music
        lda tw_dp
        tfr a,dp
        ldx tw_base
        tst tw_started
        bne tw_again
        inc tw_started
        jsr ,x                    ; entry: clears the mixer's state, starts the stream
        bra tw_back
tw_again
        jsr WIN_MIX3_RESUME,x
tw_back
        clra
        tfr a,dp                  ; the game assumes DP 0
        rts

tw_base    fdb 0
tw_dp      fcb 0
tw_started fcb 0
