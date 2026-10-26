; T0162: update_armorog, update_lifts (+ update_door, its own tail-jump
; dispatch target), and update_dagger, CODE ONLY, split out of
; logic_low.asm/gameplay.asm the same way T0148/T0161 moved
; update_dragon and update_crocodile/update_portcullis -- staged to
; CODE_DEST (block D, included right after
; rat_troll_hazard_code.asm inside room36.asm's `org CODE_DEST`
; section) so the RAW bytes they used to cost below $8000 go back into
; the shared title-hole delivery pool.
;
; WHY THESE THREE (FOUR): update_armorog and update_lifts are each
; called from exactly one site in room36.asm's mainloop (`jsr
; update_armorog` / `jsr update_lifts`), gameplay-only, verified by
; grep -- no other jsr/lbsr/bsr to either anywhere in target/.
; update_door has NO call site of its own at all: update_lifts reaches
; it with a single `lbeq update_door` tail-jump when cur_room=84 (see
; logic_low.asm's own T0134 comment, still there, for why it rides this
; dispatch instead of getting a call in mainloop -- "code+data has no
; bytes for another jsr" was literally true at the time). Since that
; tail-jump is update_lifts's OWN code, update_door has to move with
; it -- moving one without the other would leave a jump from block D
; back down into a hole. update_dagger is a separate single-call-site
; routine (`jsr update_dagger`, gameplay.asm originally) added to this
; file rather than a fourth: small and self-contained, and every
; staged-code file so far bundles what's convenient to assemble in one
; `org CODE_DEST` run rather than one routine per file (see
; croc_portcullis_code.asm's own precedent).
;
; LOCALS MOVED WITH THE CODE (own `fcb`/`fdb`/data, exported via
; staged_syms.asm exactly like dragon_code.asm's locals): ua_n/ua_slot/
; ua_seq/ua_dc (update_armorog's own scan/state) and arm_strip_hdr (a
; static blank-sprite header read ONLY by actors.asm's `ldd
; #arm_strip_hdr` -- an address constant, not a value read at a
; pass-dependent time, so it moves cleanly the same way any other
; staged-block label does); ul_n/ul_slot/ul_obstruct/ul_top/ul_bot
; (update_lifts's own scan/state -- NOT ul_orig, which stays resident,
; see below); ud_n/ud_slot (update_door's own scan state); ug_n
; (update_dagger's own scan counter). Confirmed exclusive by grep
; before moving -- nothing outside this file touches any of them.
;
; LEFT RESIDENT, DELIBERATELY NOT MOVED, because something else still
; reads or writes it from outside this file:
;   ul_bounds  -- called from update_lifts here AND from draw_lift AND
;                 from room36.asm's build_solid_actors (the lift's rope
;                 collision) -- three call sites, two of which are NOT
;                 this file's single-hardcoded-site rule, so it stays
;                 in logic_low.asm. Calling a resident subroutine from
;                 staged block D is the same proven pattern
;                 update_crocodile/update_portcullis already use for
;                 actor_hit/aabb_hit.
;   ul_orig    -- set by ul_bounds (resident) and read by draw_lift AND
;                 room36.asm's build_solid_actors (both resident,
;                 outside this file) -- never read by update_lifts
;                 itself, confirmed by grep, so there is nothing to
;                 gain moving it and a real risk in doing so.
;   draw_lift, well_route/well_air/well_seq/well_mode/well_last,
;   unpack_c, unpack_d -- all reached through something other than a
;                 single hardcoded mainloop call site (the actor draw
;                 table, room-transition code, or boot's show_title
;                 itself, which -- for unpack_c/unpack_d -- cannot
;                 live inside the very block it unpacks). Unmoved,
;                 unchanged, still in logic_low.asm.
;   ARM_*/DOOR_KNOCK_* equ constants, ROU_*/msg_* -- plain compile-time
;                 constants and resident message/actor tables; equ have
;                 no storage to move and the rest are shared globals,
;                 unchanged since T0148.
;   killed, cur_room, respawn_room/respawn_x/respawn_y, dizzy_y,
;   dizzy_x, keyflags, ah_bx/ah_by/ah_bw/ah_bh, bufA_last_x/
;   bufB_last_x -- shared globals, used everywhere, unmoved from T0148
;                 on.
;
; SAME BUILD RULE AS dragon_code.asm/croc_portcullis_code.asm/
; rat_troll_hazard_code.asm: `org CODE_DEST` directly, NOT a phase
; block -- lwasm 4.24 miscomputes relative branch offsets inside a
; phase block whenever the physical org and the phase target differ,
; and every routine here has branches. No `rmb` at the end: every local
; is an explicit `fcb`/`fdb`.
;
; Covered by:
;   update_armorog -- harness/actorlife.lua's armorog assertion
;                      (already covers his wake/run/den cycle).
;   update_lifts   -- harness/keylift.lua (referenced, not duplicated,
;                      per the T0151 actor table -- its own header
;                      covers the ride/obstruct/cogs cases).
;   update_door    -- reached only through update_lifts's own dispatch;
;                      no dedicated harness exists for room 84's door
;                      and this task's brief does not ask for one --
;                      it ships with update_lifts because it cannot be
;                      split from it, not because it has independent
;                      coverage. Flagged here rather than silently
;                      assumed safe.
;   update_dagger  -- no dedicated harness; the differential exit/edge
;                      comparison against baselines/exitcases.csv is
;                      the check for room 69, same as any other room's
;                      routine without its own actorlife assertion.
; --------------------------------------------------------------------

update_armorog
        lda cur_room
        cmpa #50
        beq ua_inroom
        rts
ua_inroom
        ldx #actor_ram
        lda #ACTOR_COUNT
        sta ua_n
ua_find
        lda ,x
        cmpa cur_room
        bne ua_next
        lda 1,x
        cmpa #ROU_ARMOROG
        beq ua_found
ua_next
        leax ACTOR_STRIDE,x
        dec ua_n
        bne ua_find
        rts
ua_found
        stx ua_slot
        lda room_load_seq
        cmpa ua_seq
        beq ua_noreset
        sta ua_seq
        lda 5,x
        cmpa #4
        beq ua_noreset
        jsr ua_reset
ua_noreset
        inc ua_dc
        lda ua_dc
        cmpa #2
        blo ua_done
        clr ua_dc
        ldy ua_slot
        jsr actor_hit
        tsta
        beq ua_nokill
        ldx #msg_armorog
        jsr kill_dizzy_msg
ua_nokill
        ldx ua_slot
        lda 5,x
        beq ua_asleep
        cmpa #1
        beq ua_countdown
        cmpa #2
        beq ua_running
ua_done
        rts
ua_asleep
        lda #ARM_WAKE_X
        sta ah_bx
        lda #ARM_WAKE_Y
        sta ah_by
        lda #ARM_WAKE_W
        sta ah_bw
        lda #ARM_WAKE_H
        jsr aabb_test          ; T0221 (was 7 bytes inline)
        beq ua_done
        ldx ua_slot
        lda #1
        sta 5,x
        lda #155
        sta 3,x
        lda #103
        sta 4,x
        lda #20
        sta 6,x
ua_countdown
        ldx ua_slot
        dec 6,x
        bne ua_done
        lda #2
        sta 5,x
ua_running
        ldx ua_slot
        lda 2,x
        adda #4
        sta 2,x
        lda 4,x
        eora #1
        sta 4,x
        lda dizzy_y
        cmpa #150
        bhs ua_intoden
        jsr ua_bone
        tsta
        beq ua_guard
ua_intoden
        ldx ua_slot
        lda 2,x
        cmpa #ARM_DEN_X
        bne ua_done
        lda 7,x
        ora #$80
        sta 7,x
        lda #156
        sta 3,x
        lda #4
        sta 5,x
        jsr force_redraw       ; T0221 (was 8 bytes inline)
        lda killed
        lbne ua_reset
        jsr ua_bone
        cmpx #0
        beq ua_nobone
        lda #255
        sta ,x
ua_nobone
        jsr msg_begin
        ldx #msg_fedarmorog
        jsr msg_box_done       ; T0221 (was 9 bytes inline)
        rts
ua_guard
        ldx ua_slot
        lda 2,x
        cmpa #ARM_GUARD_X
        lblo ua_done
        lda #3
        sta 5,x
        rts

ua_reset
        ldx ua_slot
        lda #ARM_START_X
        sta 2,x
        lda #156
        sta 3,x
        lda #102
        sta 4,x
        clr 5,x
        clr 6,x
        lda 7,x
        anda #$7f
        sta 7,x
        clr ua_dc
        jsr force_redraw       ; T0221 (was 8 bytes inline)
        rts

ua_bone
        ldx #actor_ram
        lda #ACTOR_COUNT
        sta ua_n
ub_lp
        lda 4,x
        cmpa #ARM_BONE_FRAME
        beq ub_found
        leax ACTOR_STRIDE,x
        dec ua_n
        bne ub_lp
        ldx #0
        clra
        rts
ub_found
        lda ,x
        cmpa #50
        bne ub_no
        lda 2,x
        cmpa #192
        blo ub_no
        lda 3,x
        cmpa #140
        blo ub_no
        lda #1
        rts
ub_no   clra
        rts

; --------------------------------------------------------------------
; update_lifts: see logic_low.asm's own T0124 comment (still there,
; kept with ul_bounds/draw_lift) for the full mechanism writeup.
; --------------------------------------------------------------------
update_lifts
        lda cur_room
        cmpa #71
        beq ul_scan
        cmpa #56
        beq ul_scan
        cmpa #84
        lbeq update_door
        if TAPE_ROOMS
        cmpa #40
        beq ul_scan
        cmpa #88
        beq ul_scan
        cmpa #94
        beq ul_scan
        endif
        rts
ul_scan
        if TAPE_ROOMS
; T0238: rooms 40/88/94's lifts live in actor_init_tape, not actor_ram
; -- a second pass through the SAME ul_lp body (T0234's own "second
; entry point into one shared loop" shape, draw_actors_tape's pattern)
; via a small shared helper so the loop body isn't duplicated.
        ldx #actor_ram
        lda #ACTOR_COUNT
        jsr ul_scan_tbl
        ldx #actor_init_tape
        lda #ACTOR_COUNT_tape
        jsr ul_scan_tbl
        rts
ul_scan_tbl
        sta ul_n
ul_lp
        lda ,x
        cmpa cur_room
        bne ul_next
        lda 1,x
        cmpa #ROU_LIFT
        bne ul_next
        stx ul_slot
        jsr ul_one
        ldx ul_slot
ul_next
        leax ACTOR_STRIDE,x
        dec ul_n
        bne ul_lp
        rts
        else
        ldx #actor_ram
        lda #ACTOR_COUNT
        sta ul_n
ul_lp
        lda ,x
        cmpa cur_room
        bne ul_next
        lda 1,x
        cmpa #ROU_LIFT
        bne ul_next
        stx ul_slot
        jsr ul_one
        ldx ul_slot
ul_next
        leax ACTOR_STRIDE,x
        dec ul_n
        bne ul_lp
        rts
        endif

ul_one
        if TAPE_ROOMS
        ; T0255: the room-94 lift (movingdata z62) has delay 2 like the switch and Daisy: it runs on every 2nd actor tick
        ; (d94 is the shared parity, flipped once per tick by update_switch1 in tape_code.asm; run when it reads 1).
        lda cur_room
        cmpa #94
        bne ul_gate_ok
        tst d94
        lbeq ul_ret
ul_gate_ok
        endif
        lda 5,x
        lbeq ul_ret
        lda 2,x
        sta ah_bx
        lda 3,x
        suba #2
        sta ah_by
        lda #32
        sta ah_bw
        lda #48
        jsr aabb_test          ; T0221 (was 7 bytes inline)
        beq ul_clear
        lda #2
        jsr aabb_test          ; T0221 (was 7 bytes inline)
        beq ul_notcogs
        ldx #msg_liftcogs
        jmp kill_dizzy_msg
ul_notcogs
        ldx ul_slot
        lda dizzy_x
        suba 2,x
        cmpa #12
        bhs ul_stop
        lda dizzy_dir
        bne ul_stop
        tst dizzy_dy
        bpl ul_move
ul_stop
        lda #2
        sta 6,x
        lda ul_obstruct
        inca
        anda #63
        sta ul_obstruct
        bne ul_round
        jsr msg_begin
        ldx #msg_obstructlift
        jsr msg_box_done       ; T0221 (was 9 bytes inline)
        bra ul_round
ul_clear
        clr ul_obstruct
ul_move
ul_round
        ldx ul_slot
        lda 6,x
        beq ul_just
        dec 6,x
        bne ul_ret
ul_just
        lda 5,x
        beq ul_ret
        adda 3,x
        sta 3,x
        sta ul_y
        lda cur_room
        jsr ul_bounds
        ldx ul_slot
        lda ul_y
        cmpa ul_top
        beq ul_turn
        cmpa ul_bot
        bne ul_ret
ul_turn
        neg 5,x
        lda #50
        sta 6,x
ul_ret
        rts

; --------------------------------------------------------------------
; update_door: see logic_low.asm's own T0134 comment (still there) for
; the full mechanism writeup. Reached only via update_lifts's
; `lbeq update_door` above, room 84.
; --------------------------------------------------------------------
update_door
        ldx #actor_ram
        lda #ACTOR_COUNT
        sta ud_n
ud_find
        lda ,x
        cmpa #84
        bne ud_next
        lda 1,x
        cmpa #ROU_DOOR
        beq ud_found
ud_next
        leax ACTOR_STRIDE,x
        dec ud_n
        bne ud_find
        rts
ud_found
        lda 5,x
        bne ud_ret
        lda dizzy_seq
        bne ud_ret
        stx ud_slot
        lda #DOOR_KNOCK_X
        sta ah_bx
        lda #DOOR_KNOCK_Y
        sta ah_by
        lda #DOOR_KNOCK_W
        sta ah_bw
        lda #DOOR_KNOCK_H
        jsr aabb_test          ; T0221 (was 7 bytes inline)
        beq ud_ret
        ldx ud_slot
        lda #1
        sta 5,x
        ldx #msg_knockandenter
        jsr msg_chatter
        jsr force_redraw       ; T0221 (was 8 bytes inline)
ud_ret
        rts

; --------------------------------------------------------------------
; update_dagger: X-ALL.TXT's daggerrou, room 69's trap. See
; gameplay.asm's own T0070 comment (still there) for the writeup.
; --------------------------------------------------------------------
update_dagger
        lda cur_room
        cmpa #69
        beq ug_inroom
        rts
ug_inroom
        ldx #actor_ram
        lda #ACTOR_COUNT
        sta ug_n
ug_find
        lda ,x
        cmpa cur_room
        bne ug_findnext
        lda 1,x
        cmpa #ROU_DAGGER
        beq ug_found
ug_findnext
        leax ACTOR_STRIDE,x
        dec ug_n
        bne ug_find
        rts
ug_found
        tfr x,y
        jsr actor_hit
        tsta
        beq ug_done

        lda #84
        jsr room_exists
        tsta
        beq ug_nocheckpoint
        lda #84
        sta respawn_room
        lda #224
        sta respawn_x
        lda #176
        sta respawn_y
ug_nocheckpoint
        ldx #msg_daggers
        jsr kill_dizzy_msg
ug_done
        rts

ua_n            fcb 0
ua_slot         fdb 0
ua_seq          fcb 0
ua_dc           fcb 0
arm_strip_hdr   fcb 4,20,1
        fcb 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
ul_n            fcb 0
ul_slot         fdb 0
ul_obstruct     fcb 0
d94             fcb 0     ; T0255: room 94 delay-2 parity (lift / switch1 / Daisy), see ul_one
ul_y            fcb 0
ul_top          fcb 0
ul_bot          fcb 0
ud_n            fcb 0
ud_slot         fdb 0
ug_n            fcb 0
