; --------------------------------------------------------------------
; T0229: DYLAN (room 59, frame 34) and DOUG (room 88, frame 36).
; X-ALL.TXT talkingtopeople (2378): talkbefore[frame-32] = 0 -> set to 1 and run
; the person's stream via chatter (the leading `defw` is poked with roomno);
; != 0 -> jump to the person's routine, dylanrou (2427: trancemess) /
; dougrou (2424: goonmysonmess), a single box. So:
;   Dylan: 1st talk msg_dylantalking (3 boxes; his `defw duffmem` is a dummy poke),
;          every later talk msg_trance.
;   Doug:  1st talk msg_dougtalking (6 boxes) AND crowbarhere+room := roomno (the
;          crowbar record starts in room 255, roompack ORIG_ROOM_LABELS), every
;          later talk msg_goonmyson.
; tape_talk is called from tp_take (actors.asm) for every person but Denzil
; (33), with A = the frame and Y = the record; returns X = the stream. Anyone
; else (never in a tape room) gets Denzil's text, as before.
; tt_dylan/tt_doug are the two talkbefore bytes, cleared by tape_state_reset (tape_code.asm).
; This file is included in the TAPE_LOW_REGION slot (room36.asm) after tape_win_code.asm.
DOUG_CROWBAR    equ actor_init_tape+16*ACTOR_STRIDE
tt_dylan        fcb 0
tt_doug         fcb 0
tape_talk
        cmpa #32
        bne tt_notdozy
        jmp dozy_talk            ; tail call (LOW3): its rts returns to tp_take
tt_notdozy
        cmpa #34
        bne tt_nodylan
        ldx #msg_dylantalking
        tst tt_dylan
        bne tt_trance
        inc tt_dylan
        rts
tt_trance
        ldx #msg_trance
        rts
tt_nodylan
        cmpa #36
        bne tt_denzil
        ldx #msg_dougtalking
        tst tt_doug
        bne tt_goon
        inc tt_doug
        lda cur_room
        sta DOUG_CROWBAR         ; crowbarhere+room := roomno
        rts
tt_goon
        ldx #msg_goonmyson
        rts
tt_denzil
        ldx #msg_denzil
        rts

; T0230: moved here from tape_item_code.asm (LOW3 is full)
; actors.asm tp_reallytake, after the inventory screen closed: checkholdinghole X:2520, which
; the original runs every pass: when the NEWEST carried item (slot 0) is the hole (frame 11),
; every carried item -- the hole included -- is dropped (dropobject) and holdingholemess is shown.
; Only a pickup can put the hole in slot 0 (a drop slides the list), so checking here is the same.
; Base-table items only (slot <= 100): the hole is in room 72's base record.
FRAME_HOLE_T    equ 11
        if TAPE_HOLE
tape_hole_check
        lda inv
        beq th_ret
        cmpa #100
        bhi th_ret
        deca
        ldb #ACTOR_STRIDE
        mul
        addd #actor_ram
        tfr d,x
        lda 4,x
        cmpa #FRAME_HOLE_T
        bne th_ret
        clrb
th_loop
        ldx #inv
        abx
        lda ,x
        beq th_msg
        clr ,x
        sta drop_slot
        pshs b
        jsr drop_to_world
        puls b
        incb
        cmpb #INV_SLOTS
        blo th_loop
th_msg
        jsr msg_begin
        ldx #msg_holdinghole
        jmp msg_box_done
th_ret
        rts
        endif

; T0230: moved here from tape_item_code.asm (LOW3 is full)
; actors.asm show_inventory (TAPE build): tape_slot_name: A = the inv slot value (actor index + 1,
; > 100 for the tape table) -> D = the name message; it finds the record, then falls into
; tape_item_name (A = the frame, X = the record). The original names an item by its RECORD's message pointer
; (movingdata oldmovex, printcarryingline X:5766), the port's item_name_tab is keyed by FRAME,
; which is wrong for the full bucket (frame 5 like the empty one) and missing for the tape
; frames. The full bucket is told apart by record (full_bucket); tin_tab holds the tape-only
; frames; everything else falls through to item_name_tab.
tape_slot_name
        ldx #actor_ram
        cmpa #100
        bls tsn_have
        suba #100                    ; a tape-table item (try_pickup's second pass)
        ldx #actor_init_tape
tsn_have
        deca
        ldb #ACTOR_STRIDE
        mul
        leax d,x
        lda 4,x                      ; its frame
tape_item_name
        cmpx full_bucket
        bne tin_chkw
        ldd #msg_name_fullbucket
        rts
tin_chkw
        lda 4,x                      ; T0230: the whiskey once dropped (var1 <> 0) is the empty
        cmpa #FRAME_WHISKEY_T        ; bottle: the record's name pointer := emptybottlemess (X:5862)
        bne tin_scan
        tst 5,x
        beq tin_scan
        ldd #msg_name_emptybottle
        rts
tin_scan
        ldy #tin_tab
tin_l
        ldb ,y
        beq tin_base
        cmpb 4,x
        beq tin_hit
        leay 3,y
        bra tin_l
tin_hit
        ldd 1,y
        rts
tin_base
        jmp item_name_msg
tin_tab
        fcb FRAME_KNOCKER
        fdb msg_name_knocker
        fcb FRAME_RUG
        fdb msg_name_rug
        fcb 10                       ; T0230: the records' own messages, X:1085-1115
        fdb msg_name_egg
        fcb 15
        fdb msg_name_potion
        fcb 4
        fdb msg_name_crowbar
        fcb 204
        fdb msg_name_window
        fcb 0

; ---------------------------------------------------------------------------------------
; T0230: the whiskey (droppingwhiskey X:5858 + checkifdrunk X:2947).
; tape_drop_hook (inv_select, text_src/actors.asm, right after drop_slot is set; A = the slot value):
; `tryingtodrop` X:5819 `cp 18 / call z,droppingwhiskey` -- dropping the whiskey FROM THE
; INVENTORY the first time (its var1 = 0; the auto-drop of a full bag does not come through
; here, as in the original) sets var1 := 1 (the record's byte 5, which also flips its inventory
; name to emptybottlemess, see tape_item_name), drunk := 255 and shows dropwhiskeymess.
FRAME_WHISKEY_T equ 18
drunk           fcb 0
tape_drop_hook
        cmpa #100
        bhi tdh_ret                  ; a tape-table item: never the whiskey
        deca
        ldb #ACTOR_STRIDE
        mul
        addd #actor_ram
        tfr d,x
        lda 4,x
        cmpa #FRAME_WHISKEY_T
        bne tdh_ret
        tst 5,x
        bne tdh_ret                  ; not the first time
        inc 5,x
        lda #255
        sta drunk
        jsr msg_begin
        ldx #msg_dropwhiskey
        jmp msg_box_done
tdh_ret
        rts

; tape_drunk_tick (room36.asm main loop, once per pass): checkifdrunk X:2947. drunk counts
; down; when it reaches a multiple of 64 (ticks 63,127,191,255 after the drop) and Dizzy's
; `sequence` < 2 (standing or walking left: here jump_on = 0 and dizzy_dir < 2), he falls
; over: dy = 0, animation = 1 (jump_anim), right = random bit, left = its complement,
; sequence = 4 + bit (a jump left/right: jump_on = $80, dizzy_dir = 1 + bit). Otherwise `drunk` is
; put back and the next pass retries.
tape_drunk_tick
        lda drunk
        beq tdt_ret
        deca
        sta drunk
        anda #63
        bne tdt_ret
        tst jump_on
        bne tdt_again
        lda dizzy_dir
        cmpa #2
        bhs tdt_again
        jsr hd_random
        anda #1
        inca
        sta dizzy_dir
        clr dizzy_dy
        lda #1
        sta jump_anim
        lda #$80                     ; jump_on = $80: a fall-over, see ml_landed (room36.asm)
        sta jump_on
tdt_ret
        rts
tdt_again
        inc drunk
        rts
