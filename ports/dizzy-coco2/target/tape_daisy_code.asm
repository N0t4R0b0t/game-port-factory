; T0228: Daisy in her prison (room 94) and the heart demo. TAPE build only; assembled
; into TAPE_LOW_REGION3 after tape_code.asm (room36.asm). Same rules as the other
; tape_*_code.asm files: branches inside this file may be short, everything outside
; it is reached with jsr/jmp/lbra (the raw pass parks the slot far away).
;
; X-ALL.TXT (cited by line):
;   daisyrou 3492: Daisy (daisyhere, room 94, routine `daisy`, frame 35) stands on
;     the lift. Dizzy touching her (collidewithdizzy16) with sequence == 0 starts
;     the meeting: `ld a,3 / call starttune`, gottodaisymess (a box that waits for a
;     key), theheartdemo, then roomno=94, daisyhere.room := 255, daisy1here.room :=
;     73, daisyrunsmess (windowrou), `jp musicoff`. Not touching: justinlift
;     (3530) -- her y := daisylifthere.movey + 21, so she rides the lift down.
;     `sequence` 0 = Dizzy on the ground with no direction/jump key (1 left, 2
;     right, 3+ jumping, 6/7 dying): in the port that is dizzy_dir == 0 and jump_on
;     == 0 (the same two bytes room36.asm's mainloop derives from keyflags).
;   theheartdemo 3517: dontupdatedizzy, roomno := 3, roomsetup (clearplayarea,
;     drawfullroom = room 3's two placements, printroomname), then heartdemo =
;     resethearts + 255 x updatehearts. The SAME routine ends the win sequence
;     (doendmessages 3565: `jr theheartdemo` after the gotallcoins boxes).
;   HEART DEMO 3590-3715: 32 hearts, table (age, path) per heart. Ages start 0,8..248.
;     Each updatehearts: erase (xor) the heart, age += 4, draw (xor) it. Size from age
;     bits 5-6 (0 = not drawn, else frames 29/30/31). Position: phase = (path +- age)
;     & 127 (the direction flips every demo: addpatch self-modifies add/sub),
;     x = 62 + (age * sin(phase)) >> 8, y = 110 + 3 * (age * sin(phase+32)) >> 8
;     (8-bit wraps as in the Z80), clipped by `frame` to the window (x units 34..93,
;     y 48..183), plotted XOR (frmplot 1).
;
; WIN SEQUENCE WITH MUSIC (the decision, on evidence): the original plays tune 3 from
; the start of the sequence through the heart demo; the mixer (tape_win_code.asm) is a
; CPU-bound sample loop with no spare time (a heart update takes ~40 ms of CPU, a tune
; frame is 20 ms of samples: interleaving would play the tune at about a third of its
; speed with gaps). So the tune plays under the boxes (as T0221), is silent during the
; hearts, and for Daisy's meeting RESUMES under daisyrunsmess where it stopped.
;
; The hearts' 32-entry table and all the demo's scratch variables live in the HIDDEN
; framebuffer (the demo draws on the live page and nothing flips): one 256-byte page at
; buffer start + HD_PAGE_OFF, above the mixer blob and ITS direct page so the tune can resume
; after the demo. The demo runs with DP pointing at that page (variables = 2-byte direct
; operands); `>` forces the few extended accesses to resident/persistent bytes. Only
; hd_dir/hd_seed, which must outlive a demo, sit in this file.

HD_PAGE_OFF     equ $1700             ; the last-but-one page of the 6144-byte hidden buffer
HD_TAB_OFF      equ $17c0             ; the table: 32 x (age, path) = its last 64 bytes
        ifgt WIN_DP_PAGES*256+256-HD_PAGE_OFF
        error "heart page would overlap the completion-tune mixer's DP page"
        endif
; direct-page variables (offsets in the page)
hd_tab  equ 0                         ; 2: table pointer
hd_cnt  equ 2
hd_n    equ 3
hd_size equ 4
hd_ph   equ 5
hd_x    equ 6
hd_y    equ 7
hd_t    equ 8
hd_c2   equ 9
hd_rows equ 10
hd_k    equ 11                        ; byte multiplier: 16 (sprite 4 px in) or 1 (aligned)
hd_mask equ 12                        ; 2
HD_WIN_TOP      equ 48
HD_WIN_BOT      equ 184

; ---------------------------------------------------------------------
; ud94_daisy: called by update_switch1 (tape_code.asm) every pass in room 94, after
; it has found the lift (us1_lift: its record, or 0).
; ---------------------------------------------------------------------
ud94_daisy
        lda #ROU_DAISY
        bsr td_find
        cmpx #0
        beq udd_ret
        lda ,x
        cmpa cur_room
        bne udd_ret               ; she has already gone to room 73
        stx udd_rec
        tfr x,y
        jsr actor_hit
        tsta
        bne udd_hit
        ldy us1_lift              ; justinlift: y := lift y + 21
        beq udd_ret
        ldx udd_rec
        lda 3,y
        adda #21
        sta 3,x
        lda 7,x                   ; T0255: anidaisy -- the colour's bit 7 (= drawn mirrored) flips on every run
        eora #$80
        sta 7,x
udd_ret
        rts
udd_hit
        lda dizzy_dir             ; `ld a,(sequence) / and a / ret nz`
        ora jump_on
        bne udd_ret
        jsr tape_win_init         ; starttune 3
        ldx #msg_gottodaisy
        jsr tape_win_one          ; gottodaisymess + handoffandwait
        jsr tape_heart_demo
        if FLOPPY
        jsr tape_win_reblob       ; T0241: the demo overlay overwrote the completion-tune blob: unpack it again for daisyrunsmess
        endif
        ldx udd_rec
        lda #255
        sta ,x                    ; daisyhere.room := 255
        lda #ROU_DAISY1
        bsr td_find
        lda #73
        sta ,x                    ; daisy1here.room := 73
        ldx #msg_daisyruns
        jsr tape_win_one          ; daisyrunsmess; musicoff = the box's own SPACE
        jsr box_reset             ; T0258 (D1): windowrou1's resetuproom
        jmp force_redraw
udd_rec fdb 0

; A = routine id -> X = its record in actor_init_tape, or 0.
td_find
        ldx #actor_init_tape
        ldb #ACTOR_COUNT_tape
tdf_l
        cmpa 1,x
        beq tdf_ret
        leax ACTOR_STRIDE,x
        decb
        bne tdf_l
        ldx #0
tdf_ret
        rts

        if FLOPPY
; T0241: the floppy build keeps only hd_random + hd_dir/hd_seed resident; the demo itself is an overlay
; (floppy_code.asm's tape_heart_demo stub loads OVL_HEART_A/B into the hidden framebuffer and calls it).
HEART_RES equ 1
        include "tape_heart_code.asm"
        else
        include "tape_heart_code.asm"     ; T0241: split out of this file (byte-identical in the tape build)
        endif
