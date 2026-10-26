; --------------------------------------------------------------------
; T0027: live actors -- items, pickup and the carry inventory.
;
; The actor table (actor_data.asm) is ROM initialiser data copied into
; `actor_ram` at startup, matching how the original treats `movingdata`
; as live state: picking an item up sets its room to 255, so it stays
; gone when you leave the room and come back.
;
; Slot layout (ACTOR_STRIDE = 8): room, routine id, x, y, frame, v1, v2,
; colour. Routine ids follow the original's own movingrous order.
;
; DEVIATION from the original, deliberate: the original's carry list
; stores `slotno` values and uses the literal value 1 as an
; end-of-list sentinel, which makes slot 1 and "list ends here"
; ambiguous. This port stores actor index + 1 (so 0 means empty) and
; keeps the capacity in its own byte, `inv_cap`. Same behaviour --
; newest item first, oldest dropped when full, capacity growable by the
; bag -- without the overloaded value.
; --------------------------------------------------------------------

INV_SLOTS    equ 4        ; physical slots; inv_cap says how many are usable
PICKUP_COOLDOWN equ 10    ; T0237: actor ticks (X-ALL `usepickup`=10; 7.5 passes) -- edge-detects the pickup key
                          ; without needing a second scankeys bit, matching
                          ; the original's `usepickup` one-shot guard

actors_init
        ldx #actor_init
        ldy #actor_ram
        ldd #ACTOR_COUNT*ACTOR_STRIDE
        std ai_n
ai_loop
        lda ,x+
        sta ,y+
        ldd ai_n
        subd #1
        std ai_n
        bne ai_loop
        ; empty inventory, three usable slots (the bag would make it four)
        clr inv
        clr inv+1
        clr inv+2
        clr inv+3
        lda #3
        sta inv_cap
        clr pickup_timer
        lda #3                   ; T0255: restart the 4-per-3 actor clock (actors_pass) at the same phase every game
        sta actor_acc

        ; T0057: coins. The original's `resetcoins` sets `coins` to 255
        ; so that its `addtocoins` (which increments BEFORE displaying)
        ; shows 0 for the first one found -- i.e. its counter is "coins
        ; found after this one", a quirk of that routine's structure.
        ; This port's status strip already reads `coins` directly, so it
        ; starts at a plain 0 and counts 1,2,3...
        ldx #coin_init
        ldy #coin_ram
        ldb #COIN_COUNT*COIN_STRIDE
ai_cloop
        lda ,x+
        sta ,y+
        decb
        bne ai_cloop
        clr coins
        rts

        if TAPE_ROOMS
; --------------------------------------------------------------------
; T0234: reset_tape_actors -- the SAME job as actors_init above, for
; the tape-only region's own table. That table has no separate ROM
; master to copy from (T0230's own "delivered raw, no relocation"
; design, room36.asm's own comment at its include site) -- its
; assembled fcb bytes ARE the live record, so a picked-up/moved item
; used to stay changed for the rest of the tape session, including
; across a game over -> new game. Reported as a real bug (non-
; resetting rooms after game over) -- fixed by restoring FROM a
; second, pristine copy (actor_init_tape_template, tools/roompack's
; --actor-template, tools/regen_art.sh's own note) instead, the exact
; role actor_init (ROM, LZ-packed) plays for actor_ram above.
;
; T0236: also restores coin_init_tape the same way (coin_init_tape_
; template, tools/roompack's --coin-suffix/--coins-only/--actor-
; template) -- same "delivered raw, no ROM master" reasoning applies to
; the tape-only coin table (T0057's "not an actor" mechanic, but the
; SAME raw-delivery limitation as the actor table it sits next to).
; Shares tape_block_copy's loop body instead of a second copy of it --
; every byte here counts against the tape-only region's own free-space
; budget (NOTES.md T0235).
; --------------------------------------------------------------------
tape_block_copy           ; X=src, Y=dst, B=byte count (<=255); trashes A
tbc_loop
        lda ,x+
        sta ,y+
        decb
        bne tbc_loop
        rts

reset_tape_actors
        ldx #actor_init_tape_template
        ldy #actor_init_tape
        ldb #ACTOR_COUNT_tape*ACTOR_STRIDE_tape
        jsr tape_block_copy
        ldx #coin_init_tape_template
        ldy #coin_init_tape
        ldb #COIN_COUNT_tape*COIN_STRIDE_tape
        jsr tape_block_copy
        jmp tape_state_reset     ; T0216/T0239 (tape_code.asm): per-dragon state -- its own rts returns to our caller
        endif

; --------------------------------------------------------------------
; actor_sprite: A = frame id -> U = sprite header pointer, or U = 0 when
; this build has no art for that frame. A linear scan over a short dense
; (frame, ptr) list, not a 256-entry lookup table: only a handful of
; frames have art, and 512 bytes of mostly-zero table is what pushed an
; earlier build into the framebuffer (see NOTES.md memory budget).
; --------------------------------------------------------------------
actor_sprite                     ; A = frame id -> U = header ptr, or 0
        pshs a
        ldx #actor_spr_tab
as_scan
        ldb ,x+                  ; candidate frame id
        beq as_none              ; 0 terminator: no art for this frame
        cmpb ,s
        beq as_hit
        leax 2,x                 ; skip this entry's pointer
        bra as_scan
as_hit
        ldu ,x
        puls a
        rts
as_none
        if TAPE_ROOMS
        ; T0234: the base table's own terminator -- also try the
        ; tape-only region's own sprite table before giving up. Its
        ; OWN terminator (as_none2) must NOT loop back here, or a
        ; frame missing from both would scan actor_spr_tab_tape
        ; forever.
        ldx #actor_spr_tab_tape
as_scan2
        ldb ,x+
        beq as_none2
        cmpb ,s
        beq as_hit
        leax 2,x
        bra as_scan2
as_none2
        endif
        ldu #0
        puls a
        rts

; --------------------------------------------------------------------
; draw_actors: draw every actor whose room is the current one. Like the
; flames, each clears its own box first -- `blit` only ORs ink on, and
; the damage-rect redraw only clears around Dizzy.
; --------------------------------------------------------------------
draw_actors
        ldy #actor_ram
        lda #ACTOR_COUNT
        sta da_n
da_loop
        jsr tick_poll             ; T0051 field-boundary sampling
        lda ,y                   ; room
        cmpa cur_room
        lbne da_next
        ; The rat is the one actor with a mirrored sprite variant (T0030
        ; follow-up, real playtest found it never visibly turned around).
        ; v1 (offset 5) holds its current facing, written by update_rat.
        ; Every other actor falls through to the normal lookup below.
        jsr actor_sprite_for     ; Y = actor -> U = the sprite that will
        bra da_havesprite        ; actually be DRAWN (mirror included)

; actor_sprite_for: Y = actor record -> U = the sprite header that
; draw_actors would use for it, mirrored variants and all, or U = 0.
;
; Factored out of draw_actors so COLLISION can ask the same question
; (T0103). Testing collision against the unmirrored sprite while the
; mirrored one is on screen puts the gator's nose on the wrong side.
actor_sprite_for
        lda 1,y                  ; routine
        cmpa #ROU_CROCODILE
        bne da_notcroc
        ; T0058: the gator turns to face Dizzy. Bit 7 of its colour byte
        ; is the facing flag -- the original's own `rev` bit, set by
        ; update_crocodile from the big proximity box.
        lda 7,y
        bpl da_normal
        lda 4,y
        cmpa #124
        beq da_crocopen
        ldu #aspr_123_mirror_w
        rts
da_crocopen
        ldu #aspr_124_mirror_w
        rts
da_notcroc
        ; T0123: Armorog faces the other way once in his den (colour bit 7,
        ; the source's `set 7,(ix+colour)`), with a mirrored pair of frames.
        cmpa #ROU_ARMOROG
        bne da_notarm
        lda 7,y
        bpl da_normal
        lda 4,y
        cmpa #103
        beq da_arm103m
        ldu #aspr_102_mirror_w
        rts
da_arm103m
        ldu #aspr_103_mirror_w
        rts
da_notarm
        ; T0124: a switched-on machine (v1 bit 0, set by its key) is drawn
        ; mirrored -- resetmachines copies var1 into colour bits 1 and 7.
        lda 1,y
        cmpa #ROU_MACHINES
        bne da_notmach
        lda 5,y
        bita #1
        beq da_normal
        ldu #aspr_127_mirror_w
        rts
da_notmach
        lda 1,y
        cmpa #ROU_RAT
        bne da_normal
        lda 5,y                  ; facing
        beq da_normal
        ldu #aspr_104_mirror_w
        rts
da_normal
        lda 4,y                  ; frame
        jsr actor_sprite
        rts
da_havesprite
        cmpu #0
        lbeq da_next
        stu cb_spr
        lda 2,y
        sta cb_x
        lda 3,y
        sta cb_y

        ; Static actors (everything except the rat) don't need clearing
        ; and redrawing EVERY frame -- they don't move, so once correct
        ; in a buffer they stay correct until something actually
        ; overlaps them. Redrawing all of them unconditionally every
        ; pass (a 32x40 troll included) was real, measured per-frame
        ; cost -- a real playtest reported ongoing slowness even after
        ; the message-spam fix (T0029-32 follow-up). Apply the SAME
        ; damage-rect overlap test the room's own static placement loop
        ; already uses (redraw's rd_placelp) -- when a buffer was just
        ; fully invalidated, redraw() sets the damage rect to the whole
        ; screen for that pass, so this test naturally still draws
        ; everything then; no separate invalidation flag needed.
        ; The rat is the one exception -- it moves under its own power
        ; every frame, outside Dizzy's damage rect entirely, so it must
        ; always be evaluated. It's small (32x7), cheap either way.
        lda 1,y
        cmpa #ROU_RAT
        lbeq da_clear                 ; rat: always redraw
        if TAPE_ROOMS
        cmpa #ROU_LOG                 ; T0216: room 48's floating log bobs
        lbeq da_clear                 ; every tick -- same always-redraw path
        cmpa #ROU_DOZYFLOAT           ; T0218: room 45's floating Dozy, same
        lbeq da_clear
        cmpa #ROU_DAISY               ; T0228: room 94's Daisy rides the lift
        lbeq da_clear                 ; (y = lift y + 21 every pass) -- same path
        cmpa #ROU_DAISY1              ; T0255: room 73's Daisy flips every run
        lbeq da_clear
        ; T0239: the hawk (room 49) moves under its own power every pass
        ; too -- same always-redraw + save-under path as the rat (they
        ; are never in the same room, so the single save slot per
        ; buffer is free). Stop drawing once a dive has taken it off
        ; the bottom: rat_save reads RAT_SV_H rows from its y, and the
        ; original's hawk is simply off-screen there too.
        cmpa #ROU_HAWK
        bne da_nothawk
        lda 3,y
        cmpa #176
        lbhs da_next
        lbra da_clear
da_nothawk
        endif

        ; T0115: room 51's gate draws itself, at rest and moving -- see
        ; draw_gate (gameplay.asm). Neither a plain blit (T0102's trail)
        ; nor an erase-then-draw is what the original does: it overwrites,
        ; and the sprite's blank bottom rows do the erasing.
        cmpa #ROU_PORTCULLIS
        bne da_notgate
        jsr draw_gate
        lbra da_next
da_notgate
        ; T0123: Armorog, once awake (v1 != 0), is redrawn every pass: waking
        ; changes his frame and y, he runs 4px per update, and he turns round
        ; in his den. While running (v1 == 2) first wipe the 4px strip he just
        ; left -- `blit` only ORs ink, and clear_and_blit clears only the box
        ; he is in now, so his left edge would otherwise smear along the run.
        cmpa #ROU_LIFT
        bne da_notlift
        jsr draw_lift             ; T0124 (logic_low.asm)
        lbra da_next
da_notlift
        cmpa #ROU_ARMOROG
        bne da_notarmdraw
        lda 5,y
        lbeq da_dmgtest           ; asleep: an ordinary static actor
        cmpa #2
        bne da_armbox
        pshs y
        ldd cb_spr
        pshs d
        lda cb_x
        suba #4
        sta cb_x
        ldd #arm_strip_hdr
        std cb_spr
        jsr clear_and_blit
        puls d
        std cb_spr
        puls y
        lda 2,y
        sta cb_x
da_armbox
        lbra da_clear
da_notarmdraw
        lda 1,y

        ; T0066: the crocodile animates IN PLACE (123/124, plus a facing
        ; flip), so the damage-rect test below -- which only asks "did
        ; something else scribble on me" -- is not enough on the pass its
        ; own sprite changes. It used to answer that by invalidating BOTH
        ; buffers entirely, repainting the whole room to move one 16x32
        ; sprite. Instead, remember what each buffer last drew for it and
        ; force only its own box when that differs. `draw_flames` has
        ; done exactly this since T0033; this is the same idea for an
        ; actor. The record packs the facing into bit 7, which is free
        ; because frames 123/124 don't use it -- and facing changes the
        ; sprite without changing the frame number, so both have to be
        ; in the comparison.
        cmpa #ROU_CROCODILE
        bne da_dmgtest
        pshs y
        jsr croc_var_ptr             ; X -> this buffer's record
        puls y
        lda 7,y                      ; colour byte: bit 7 = facing
        anda #$80
        ora 4,y                      ; ... packed with the frame
        cmpa ,x
        beq da_dmgtest               ; unchanged in this buffer
        sta ,x
        bra da_clear                 ; changed: redraw its box, nothing else
da_dmgtest

        ldu cb_spr
        lda cb_x
        lsra
        lsra
        lsra
        sta da_p_col0
        ldb 2,u                      ; bpr
        addb da_p_col0
        stb da_p_col1
        lda cb_y
        sta da_p_y0
        ldb 1,u                      ; height
        addb da_p_y0
        stb da_p_y1

        lda da_p_col0
        cmpa dmg_col1
        bhs da_next
        lda dmg_col0
        cmpa da_p_col1
        bhs da_next
        lda da_p_y0
        cmpa dmg_y1
        bhs da_next
        lda dmg_y0
        cmpa da_p_y1
        bhs da_next
da_clear
        ; da_clear is reached by TWO different cases -- the rat (always,
        ; unconditionally) and any STATIC actor whose box happens to
        ; overlap the current damage rect (falls through from the AABB
        ; test above). They are NOT the same case and must not share a
        ; draw routine: rat_clear_and_blit tracks "where was I drawn
        ; last, in THIS buffer" in rat_lastx_a/b, meaning-per-rat -- if
        ; a static actor (troll/apple/jug/loaf) also called it, it would
        ; read and overwrite that SAME pair of variables, so its "old
        ; position" would actually be wherever some UNRELATED actor was
        ; last drawn, and the clear rectangle computed from that
        ; garbage could span anywhere between the two. Real playtest,
        ; after this was wrongly shared for one build: pickupable items
        ; only rendering near Dizzy, AND the rat's own trail-fix
        ; regressing. Static actors never move, so they never needed
        ; rat_clear_and_blit's whole reason to exist in the first place
        ; -- clear_and_blit (this file's original, simpler routine,
        ; clears only the current spot, no last-position state at all)
        ; is correct for them and was sitting unused by mistake.
        lda 1,y
        cmpa #ROU_RAT
        beq da_userat
        if TAPE_ROOMS
        cmpa #ROU_HAWK
        beq da_userat
        cmpa #ROU_LOG             ; T0216: log shares the rat's save-under (32x7)
        beq da_userat
        cmpa #ROU_DOZYFLOAT       ; T0218: so does Dozy (24x28, see rat_sv_setup)
        beq da_userat
        cmpa #ROU_DAISY           ; T0228: and Daisy (24x19)
        beq da_userat
        cmpa #ROU_DAISY1          ; T0255: and the Daisy of room 73 (she flips too)
        beq da_userat
        endif
        cmpa #ROU_PORTCULLIS
        bne da_clear_static
da_userat
        if TAPE_ROOMS
        lda 1,y                   ; T0255: Daisy (94 / 73) flips every run: colour bit 7 = drawn mirrored (anidaisy)
        cmpa #ROU_DAISY
        beq da_ur_mir
        cmpa #ROU_DAISY1
        bne da_ur_go
da_ur_mir
        jsr tape_static_mirror
da_ur_go
        endif
        pshs y
        jsr rat_clear_and_blit
        puls y
        bra da_next
da_clear_static
        ; T0063: a plain PICKUPABLE never reanimates or moves once
        ; placed/dropped, so it needs no pre-clear -- the room's own
        ; floor/wall art was already restored by redraw_placements_dmg
        ; earlier THIS SAME PASS, and clear_and_blit's clear would just
        ; black out whatever of it the item's own sprite doesn't cover.
        ; The troll and crocodile stay on clear_and_blit: the troll
        ; moves during its tumble and the crocodile's sprite frame
        ; toggles (123/124) while parked, so both have a previous draw
        ; that genuinely needs erasing before the new one goes down.
        lda 1,y
        cmpa #ROU_PICKUPABLE
        bne da_needs_clear
        pshs y
        jsr blit_only
        puls y
        bra da_next
da_needs_clear
        if TAPE_ROOMS
        cmpa #ROU_CROWBAR        ; T0223: A = routine. The shopkeeper's second
        beq da_nc_mir            ; half (frame 105, colour bit 7) is a static
        cmpa #ROU_SWITCH1        ; T0255: the two levers (resetmachines: var1 ->
        beq da_nc_mir            ; colour bit 7) are drawn mirrored too
        cmpa #ROU_PORTSWITCH
        bne da_nc_go
da_nc_mir
        jsr tape_static_mirror   ; actor drawn mirrored (tape_bean_code.asm)
da_nc_go
        endif
        pshs y
        jsr clear_and_blit
        puls y
da_next
        leay ACTOR_STRIDE,y
        dec da_n
        lbne da_loop
        rts

        if TAPE_ROOMS
; --------------------------------------------------------------------
; T0234: draw_actors_tape -- the tape-only region's own actor table
; (actor_tape, ACTOR_COUNT_tape). Reuses da_loop's own body entirely
; (every branch in it reads Y/ACTOR_STRIDE generically, no table-
; specific addressing anywhere in it) -- only the starting table base,
; count and tick_poll setup differ, so this is just a second entry
; point INTO the existing loop, not a duplicate of it. Called from
; room36.asm's mainloop, gated on TAPE_ROOMS, straight after
; draw_actors itself.
; --------------------------------------------------------------------
draw_actors_tape
        ldy #actor_init_tape
        lda #ACTOR_COUNT_tape
        sta da_n
        lbra da_loop
        endif

; --------------------------------------------------------------------
; actor_hit: does the actor at Y overlap Dizzy? AABB, with Dizzy's box
; narrowed the same way collision uses (BODY_L/BODY_R) so his gloves
; don't grab things he isn't really touching. Returns Z clear on a hit.
;
; Actor y is the sprite TOP (as room placements are); dizzy_y is his
; FEET, so his box is dizzy_y-dizzy_h .. dizzy_y.
; --------------------------------------------------------------------
actor_hit
        ; horizontal: actor_x < dizzy_right && dizzy_left < actor_right
        lda dizzy_x
        adda #BODY_R
        sta ah_dr                ; Dizzy right edge
        lda dizzy_x
        adda #BODY_L
        sta ah_dl
        lda 4,y
        jsr actor_sprite
        cmpu #0
        beq ah_miss
        stu ah_spr
        lda 2,y
        sta ah_ax
        ldu ah_spr
        lda ,u                   ; width
        adda ah_ax
        bcc ah_arok              ; T0138: saturate, as aabb_hit
        lda #255
ah_arok sta ah_ar                ; actor right edge

        lda ah_ax
        cmpa ah_dr
        bhs ah_miss              ; actor starts right of Dizzy
        lda ah_dl
        cmpa ah_ar
        bhs ah_miss              ; Dizzy starts right of actor

        ; vertical
        lda 3,y
        sta ah_ay
        ldu ah_spr
        lda 1,u                  ; height
        adda ah_ay
        sta ah_ab                ; actor bottom
        lda dizzy_y
        suba dizzy_h
        suba #REACH_MARGIN        ; see its own comment (room36.asm)
        sta ah_dt                ; Dizzy top

        lda ah_ay
        cmpa dizzy_y
        bhs ah_miss              ; actor below Dizzy's feet
        lda ah_dt
        cmpa ah_ab
        bhs ah_miss              ; Dizzy above the actor
        lda #1                   ; hit
        rts
ah_miss
        clra
        rts

        if TAPE_ROOMS
; --------------------------------------------------------------------
; T0236: update_daisy1 -- X-ALL.TXT's daisyrou1 (room 73, daisy1here,
; frame 35, ROU_DAISY1) -- the game's WIN trigger. Scans actor_init_tape
; for a ROU_DAISY1 entry in cur_room and tests actor_hit against it,
; the real `collidewithdizzy16` equivalent this port already has.
;
; X-ALL.TXT gates doendmessages on `ld a,(sequence)/and a/ret nz` -- a
; global "a scripted sequence is already running" flag shared by every
; cutscene-driving routine in the original. This port implements no such
; state machine anywhere (checked: no cross-routine "sequence" flag in
; target/text_src) -- there is only this one routine that would ever set
; it, so there is nothing to gate against. `completedgame` below plays
; the part that actually matters here: it stops daisyrou1 re-running its
; win path on a second touch.
; --------------------------------------------------------------------
update_daisy1
        lda completedgame
        bne ud1_done              ; already won -- mainloop ends the
                                    ; game the instant it sees this set
        lda cur_room              ; T0255: daisyrou1 has delay 2 (movingdata z67): it runs on every 2nd tick spent in
        cmpa #73                  ; her room (the delay counter only advances there), and `anidaisy` flips her
        bne ud1_done              ; colour bit 7 (= drawn mirrored) on each run that is not a conversation
        lda ud1_par
        eora #1
        sta ud1_par
        bne ud1_done              ; new value 1 = the first tick of the pair: skip
        ldy #actor_init_tape
        lda #ACTOR_COUNT_tape
        sta ud1_n
ud1_loop
        lda ,y
        cmpa cur_room
        bne ud1_next
        lda 1,y
        cmpa #ROU_DAISY1
        bne ud1_next
        jsr actor_hit
        tsta
        bne ud1_hit
        lda 7,y
        eora #$80
        sta 7,y
ud1_next
        leay ACTOR_STRIDE,y
        dec ud1_n
        bne ud1_loop
ud1_done
        rts

; X-ALL.TXT doendmessages: `ld a,(coins)/cp 30/jp nz,chatter` (nag,
; notgotallcoins) `/ ... starttune 3 / completedgame=1 / chatter
; (gotallcoins) / theheartdemo` (win). The heart demo visual sequence is
; NOT ported (NOTES.md T0236; ported by T0228, see ud1_win below). T0221: the completion tune IS -- see
; tape_win_code.asm (tune3 through the title's 3-voice mixer, under the
; gotallcoins boxes). mainloop
; (room36.asm) reads `completedgame` itself, right after calling this
; routine, to end the game exactly where X-ALL.TXT's own mainloop does
; (`ld a,(completedgame)/and a/jr nz,quitted`, line 1357).
ud1_hit
        lda coins
        cmpa #30
        beq ud1_win
        jsr msg_begin
        ldx #msg_notgotallcoins
        jsr msg_chatter
        jsr force_redraw       ; T0221's own reasoning -- a chatter run
                                  ; is much bigger than a damage rect
        rts
ud1_win
        lda #1
        sta completedgame
        ldx #msg_gotallcoins
        jsr tape_win_chatter   ; T0221: msg_chatter + tune3 under the boxes
                                  ; (tape_win_code.asm, TAPE_LOW_REGION)
        jsr tape_heart_demo    ; T0228: `jr theheartdemo` (X:3565), silent
                                  ; (tape_daisy_code.asm, TAPE_LOW_REGION3)
        jsr force_redraw
        rts
        endif

; --------------------------------------------------------------------
; try_pickup: the DOWN key picks up / puts down.
;
; The original uses a dedicated pickup key with a `usepickup` one-shot
; guard. This port reuses DOWN -- it is otherwise unused (Dizzy has no
; crouch) -- and edge-detects with a cooldown so holding it doesn't
; repeatedly pick up and drop. Documented as a deliberate control
; choice, not an accident of the keyboard scanner.
; --------------------------------------------------------------------
; give_rope: put the rope actor into the CURRENT room -- the port of
; talkingtopeople1's `ld (de),a` for `denziltalking`'s own
; `defw ropehere+room`. Finds the slot by frame (14) and routine, the
; same way everything else here identifies an actor, because this port
; has no per-actor label table at runtime.
give_rope
        pshs y,b
        ldy #actor_ram
        ldb #ACTOR_COUNT
gr_loop
        lda 4,y                  ; frame
        cmpa #14                 ; the rope
        bne gr_next
        lda 1,y                  ; routine
        cmpa #ROU_PICKUPABLE
        bne gr_next
        lda cur_room
        sta ,y                   ; room := here
        bra gr_done
gr_next
        leay ACTOR_STRIDE,y
        decb
        bne gr_loop
gr_done
        puls b,y
        rts

denzil_gave_rope fcb 0           ; T0199: one-shot, see the call site

; pickup_tick (T0237): X-ALL.TXT `usepickup` (10, set whenever a box is drawn) is counted
; down by the MAIN LOOP (the actor clock, 3 interrupts), not by Dizzy's update; so the
; port's timer is a table entry of mainloop's actors_tick (4 runs per 3 passes).
pickup_tick
        lda pickup_timer
        beq pkt_ret
        deca
        sta pickup_timer
pkt_ret rts
try_pickup
        lda pickup_timer
        beq tp_ready
tp_ret0 rts                      ; T0259: a nearby rts, so the short branches below reach it
tp_ready
        lda keyflags
        bita #2                  ; DOWN
        beq tp_ret0
        lda #PICKUP_COOLDOWN
        sta pickup_timer

        ; T0259 (D2): X-ALL's order -- the ACTORS first (domoving), then the coins (pickupcoins), and among the
        ; actors the one with the highest index in the original's `movingdata` (domoving walks from the LAST record
        ; down, and the first pickupable that overlaps Dizzy consumes the key press). Both tables are scanned in
        ; full and the best candidate kept: byte 6 of a pickupable record is its movingdata index (roompack).
        ; Doug versus the crowbar he makes appear: the crowbar (a later record) wins, as on the ZX.
        ; The best candidate lives on the stack for the whole scan: ,s = its index, 1,s = B, 2,s = its record.
        clra
        pshs y,b,a

        ; look for a pickupable actor in this room overlapping Dizzy
        if TAPE_ROOMS
        clr tp_scan_phase
        endif
        ldy #actor_ram
        lda #ACTOR_COUNT
        sta tp_n
        clrb                     ; B = actor index
tp_loop
        lda ,y
        cmpa cur_room
        bne tp_next
        lda 1,y
        cmpa #ROU_PICKUPABLE
        bne tp_next
        pshs b
        jsr actor_hit
        puls b
        tsta
        beq tp_next
        lda 6,y                  ; T0259: movingdata index; keep the highest
        cmpa ,s
        bls tp_next
        sta ,s
        stb 1,s
        sty 2,s
tp_next
        incb
        leay ACTOR_STRIDE,y
        dec tp_n
        bne tp_loop
        if TAPE_ROOMS
        ; T0234: second pass, the tape-only region's own actor table.
        ; tp_take (unchanged, shared) does `incb / stb tp_slot`, so
        ; starting B at 100 here makes tp_slot 101..(100+N) for a tape
        ; actor, vs 1..ACTOR_COUNT for a base one -- drop_to_world and
        ; check_drop_trigger (gameplay.asm) both branch on that split to
        ; find the right table back. tp_scan_phase stops this from
        ; re-entering itself once the tape pass itself also runs out.
        tst tp_scan_phase
        bne tp_fallback
        inc tp_scan_phase
        ldy #actor_init_tape
        lda #ACTOR_COUNT_tape
        sta tp_n
        ldb #100
        bra tp_loop
        endif
tp_fallback
        puls a,b,y               ; T0259: the winner of the scan above, if any
        tsta
        beq tp_nopick
        bra tp_take
tp_nopick
        jsr pickup_coins         ; T0057: coins after the actors (X-ALL pickupcoins follows domoving),
        tsta                     ; so collecting one doesn't also open the inventory
        bne tp_ret0
        if TAPE_ROOMS
        jsr pickup_coins_tape    ; T0236: second pass, the tape-only
        tsta                     ; region's own coin table
        bne tp_ret0
        endif
        ; T0040: X-ALL.TXT's `tryputtingdown` checks `proxpicture`'s box
        ; BEFORE falling through to the inventory screen, and only while
        ; actually carrying something (`ret z` on an empty `pickup`) --
        ; reproduced here in the same order, ahead of the inventory
        ; fallback below. Doesn't consume the held item or drop
        ; anything, matching the source.
        ; T0056: NOT gated on carrying anything. X-ALL.TXT's
        ; `tryputtingdown` gates only on `pickup` -- the key having been
        ; pressed this tick -- and then checks proxpicture. This port
        ; additionally required a non-empty inventory, so walking up to
        ; the picture empty-handed and pressing DOWN did nothing, which
        ; is how it reads in play: "the picture has an action to pop up a
        ; text message" that never appears.
        lda cur_room
        cmpa #52
        bne tp_noninv
        lda #PICTURE_BOX_X
        sta ah_bx
        lda #PICTURE_BOX_Y
        sta ah_by
        lda #PICTURE_BOX_W
        sta ah_bw
        lda #PICTURE_BOX_H
        jsr aabb_test          ; T0221 (was 7 bytes inline)
        beq tp_noninv
        jsr msg_begin
        ldx #msg_picture
        jsr msg_box_done       ; T0221 (was 9 bytes inline)
        bra tp_done
tp_noninv
        ; nothing to take -> open the inventory so the player can
        ; CHOOSE what (if anything) to drop, instead of blindly
        ; dropping the newest item with no feedback (T0027's original
        ; behaviour -- see show_inventory's own comment on why this
        ; generalizes the source's own trigger for opening this screen)
        lda inv
        beq tp_done
        jsr show_inventory
        bra tp_done
tp_take
        ; T0100: FRAMES 32..39 ARE PEOPLE -- you talk to them, you do not
        ; pick them up. This is the original's own rule, keyed on the
        ; frame number exactly like the rest of pickupablerou
        ; (X-ALL.TXT ~2302):
        ;
        ;       cp 32 / jr c,notpickingupbag     ; < 32 -> pick up
        ;       cp 40 / jp c,talkingtopeople     ; 32..39 -> talk
        ;
        ; The routine id does NOT distinguish them: denzilhere carries
        ; `pickupable` just like ropehere does. What differs is the first
        ; defw -- a message for a real item (ropemess), a ROUTINE for a
        ; person (denzilrou -> windowrou). Frames 32..39 are Dozy 32,
        ; Denzil 33, Dylan 34, Daisy 35, Doug 36. Denzil is the only one
        ; in a built room so far; the rest arrive with their rooms.
        ;
        ; Without this Dizzy pocketed Denzil and the inventory listed a
        ; person as "AN OBJECT". Reported from a playtest.
        lda 4,y                  ; frame
        if TAPE_ROOMS
        jsr tape_take_hook       ; T0223/T0227 (tape_item_code.asm): the shopkeeper
        bcs tp_done              ; (105: DOWN opens the inventory, never picked up), the
        endif                    ; bag (1) and manure (3); C set = handled there
        cmpa #32
        blo tp_reallytake
        cmpa #40
        bhs tp_reallytake
        ; T0199: X-ALL.TXT `talkingtopeople1` reads the stream's leading
        ; `defw` as an ADDRESS and pokes the CURRENT ROOM into it:
        ;     ld a,(roomno) / ld e,(hl) / inc hl / ld d,(hl) / ld (de),a
        ; `denziltalking defw ropehere+room`, so Denzil MATERIALISES the
        ; rope in the room you talk to him in -- which is what his last
        ; box says he is doing. The rope's orig_room is 255, and
        ; `resetmoving` restores every actor from orig_* right after the
        ; title screen, so it is NOT in the world until this runs. We had
        ; it sitting in room 68 from the start, takeable without ever
        ; talking to him (playtest question: "is the rope supposed to be
        ; there from the start or only after talking to Denzil?").
        ;
        ; Gated by denzil_gave_rope because this port has no `talkbefore`
        ; table: without the gate, talking again after pocketing the rope
        ; would materialise a second one.
        if TAPE_ROOMS
        cmpa #33                 ; T0218/T0229: tape_talk (tape_code.asm) --
        beq dz_notdozy           ; X = the message for this talk of Dozy
        jsr tape_talk            ; (32; the 5th pushes him into the water),
        bra dz_show              ; Dylan (34) or Doug (36); Denzil goes on below
dz_notdozy
        endif
        cmpa #33                 ; A is still the frame -- Denzil only
        bne dz_norope
        tst denzil_gave_rope
        bne dz_norope
        inc denzil_gave_rope
        jsr give_rope
dz_norope
        ldx #msg_denzil
dz_show
        jsr msg_chatter
        jsr force_redraw       ; T0221 (was 8 bytes inline)
        lbra tp_done

tp_reallytake
        incb                     ; store index+1 so 0 can mean "empty"
        stb tp_slot
        ; T0255: no tune here -- X-ALL pickupablerou goes straight to inventoryrou (the box-open sound only);
        ; tune 5 belongs to COINS (pickupcoins, below).  inv_insert reads tp_slot, already stored, not B.
        lda #255
        sta ,y                   ; remove from the world -- BEFORE inv_insert:
                                    ; a full inventory auto-drops the oldest
                                    ; item via drop_to_world, whose
                                    ; update_item_triggers walks the actor
                                    ; table in Y. Storing after it hit the
                                    ; wrong actor, leaving the picked-up item
                                    ; in the room AND in the inventory
                                    ; (playtest: 4th pickup duplicated items).
        jsr inv_insert

        ; draw_actors only clears an actor's CURRENT position each
        ; frame -- an actor that just stopped being drawn (room=255
        ; above) never gets its OLD pixels erased, since neither the
        ; damage-rect (tracks only Dizzy) nor draw_actors (skips
        ; anything not in cur_room) ever touches that spot again. Left
        ; a permanent ghost of the item behind. Force both buffers to
        ; fully redraw once, same trick room transitions already use.
        jsr force_redraw       ; T0221 (was 8 bytes inline)

        jsr show_inventory        ; X-ALL.TXT's inventoryrou -- entered on
                                    ; EVERY successful pickup, not a
                                    ; separate dedicated key (see its own
                                    ; comment)
        if TAPE_ROOMS
        if TAPE_HOLE
        jsr tape_hole_check      ; T0227: checkholdinghole (tape_item_code.asm; TAPE_HOLE in room36.asm)
        endif
        endif
tp_done
        rts

; inv_insert: push tp_slot in at the front, sliding the rest down. If
; the list is already full the OLDEST item is dropped back into the
; world first, which is the original's `toomuchtohold` behaviour.
inv_insert
        lda inv_cap
        deca
        tfr a,b                  ; B = last usable index
        ldx #inv
        abx
        lda ,x                   ; occupant of the last usable slot
        beq ii_shift
        sta drop_slot
        jsr drop_to_world        ; full: oldest falls out
ii_shift
        lda inv_cap
        deca
        sta ii_i
ii_sloop
        lda ii_i
        beq ii_store
        ldx #inv
        ldb ii_i
        abx
        lda -1,x
        sta ,x
        dec ii_i
        bra ii_sloop
ii_store
        lda tp_slot
        sta inv
        rts

; --------------------------------------------------------------------
; drop_to_world: put an item back into the room at Dizzy's feet.
; drop_slot holds actor index + 1. Callers are responsible for removing
; the item from `inv` themselves first (show_inventory and inv_insert's
; own auto-drop both need slightly different removal logic, so it isn't
; done here).
; --------------------------------------------------------------------
drop_to_world
        lda drop_slot
        if TAPE_ROOMS
        lbeq dtw_done      ; T0234: same short-branch-reach note as
                            ; check_drop_trigger's own (gameplay.asm).
        else
        beq dtw_done
        endif
        if TAPE_ROOMS
        ; T0234: drop_slot > 100 means try_pickup's SECOND pass (the
        ; tape-only region's own actor table) found this item -- see
        ; its own note. addd #actor_ram below would otherwise compute a
        ; garbage address 100+ slots past the base table's own end.
        cmpa #100
        bls dtw_base
        suba #100
        deca                     ; 0-based tape-table index
        ldb #ACTOR_STRIDE
        mul
        addd #actor_init_tape
        tfr d,x
        bra dtw_havex
dtw_base
        endif
        deca                     ; back to a 0-based index
        ldb #ACTOR_STRIDE
        mul
        addd #actor_ram
        tfr d,x
dtw_havex
        lda cur_room
        sta ,x                   ; back into the world, here

        ; T0053: where a dropped item lands is not a guess -- X-ALL.TXT's
        ; `dropobject` (~5877) is explicit:
        ;     ld a,(x) / and %11111110 / add 34   -> object x
        ;     ld a,(y) / and %11111000 / sub 8    -> object y
        ; Dizzy's x is in 4-pixel units and object x carries the +32 bias
        ; (T0050), so in this port's pixels that first line is exactly
        ; "round down to a multiple of 8, then add 8" -- i.e. the item is
        ; placed up to 12px AHEAD of him, not the 4px this used to use.
        ;
        ; That difference decides whether the apple puzzle is solvable at
        ; all. Its box is x=184..200 and the troll's own box starts at
        ; 200; with a +4 drop you had to stand at 180-196 to land in it,
        ; and Dizzy is 24 wide, so every one of those positions already
        ; overlaps the troll and gets you launched before you can let go.
        ; With the source's placement, standing at 176 -- which clears the
        ; troll's box exactly -- puts the apple at 184, inside its own.
        lda dizzy_x
        anda #$f8
        adda #8
        sta 2,x

        ; T0065: the source's own `ld a,(y) / and %11111000 / sub 8`,
        ; with the ONE-PIXEL anchor difference this port has, which is
        ; the whole reason dropped items sank into the floor.
        ;
        ; `checkbottomside` (~6524) offsets its two cursors differently
        ; -- `looky` by 3 and `y` by 4 -- so the row it PROBES is y+1.
        ; The original's `y` is therefore the last CLEAR row, one above
        ; the floor; this port's dizzy_y is the first SOLID row (that is
        ; what check_ground tests). Standing on room 36's floor, whose
        ; top ink row is 176: the original holds y=175 and drops the item
        ; at (175 & $F8) - 8 = 160, so a 16px item's bottom lands on 175,
        ; resting exactly on the floor. Feeding this port's 176 into the
        ; same formula gives 168 -- eight pixels down, buried. The old
        ; -12 here was a fudge at the same problem from the other end and
        ; still left it 4px under.
        ;
        ; Subtracting 1 first puts this port on the source's anchor, and
        ; the item lands where the original puts it. The quantisation to
        ; 8px bands is the original's and is kept: an item taller than 16
        ; floats, one shorter sinks, exactly as it does there.
        lda dizzy_y
        deca                     ; the source's y: the row above the floor
        anda #$f8
        suba #8
        sta 3,x
        ; T0054: the trigger check runs HERE, on the drop action -- but
        ; it tests DIZZY against the box, not where the item landed.
        ; Both halves matter and the original has both: a pickupable's
        ; routine begins `ld a,(pickup) / and a / ret z`, so it does
        ; nothing at all unless the pickup/drop key is down that tick,
        ; while the box test it then reaches (proximitycollide/joinprox)
        ; is against Dizzy. Checking every frame instead fires the apple
        ; the instant the game starts, since the apple is already lying
        ; in room 36 and Dizzy spawns inside its box.
        jsr update_item_triggers
dtw_done
        rts

; --------------------------------------------------------------------
; show_inventory: X-ALL.TXT's inventoryrou. Opened on every successful
; pickup (matches the source: entered unconditionally from
; pickupablerou's own success path, not a separate key) and also when
; DOWN is pressed with nothing pickupable nearby but something IS
; carried -- a deliberate generalization of the source's own trigger
; (which only opens this on an auto-drop-when-full). This port lets the
; player always choose what to drop rather than only when full and
; always the oldest; a disclosed simplification of WHEN the screen
; appears, not of what it does once open.
;
; Lists every carried item by NAME (X-ALL.TXT's own item description
; text -- msg_name_* in gameplay.asm), not an icon: confirmed against a
; real playtest screenshot of the actual game, which our own HUD-icon
; approach never matched. UP/DOWN move a cursor (a leading 'X' marker,
; not '>' -- this port's font remaps '>' to a period, an already-
; documented punctuation quirk, so a real greater-than glyph isn't
; available) between the carried items and a trailing EXIT entry; SPACE
; selects: a real item is DROPPED into the world at Dizzy's position
; (drop_to_world, which itself re-checks the apple/troll and jug/fire
; puzzles against the new position -- see check_drop_triggers) and the
; screen closes; EXIT just closes without dropping anything.
;
; NOT implemented, a disclosed simplification: the source's own
; "@orig(X-ALL:1060/16) @orig(X-ALL:1072/16)" banner shown specifically when a
; pickup forces an auto-drop. This screen still opens and still shows
; the (now full) item list correctly in that case, just without that
; one extra line.
; --------------------------------------------------------------------
show_inventory
        ; Default cursor to EXIT, not the first item -- real playtest
        ; feedback: dropping should be a deliberate choice, not the
        ; path of least resistance if the player just taps SPACE out
        ; of habit. Counts occupied slots once here (the redraw loop
        ; below recomputes it again each pass too -- harmless, it's
        ; idempotent, and not worth restructuring just to skip a few
        ; cheap instructions).
        ldx #inv
        clr inv_cursor
        ldb inv_cap
        stb inv_n
si_countloop
        lda ,x+
        beq si_countdone
        inc inv_cursor
        dec inv_n
        bne si_countloop
si_countdone
inv_redraw
        jsr msg_begin

        ldx #inv
        clr inv_occupied
        ldb inv_cap
        stb inv_n
inv_countloop
        lda ,x+
        beq inv_countdone
        inc inv_occupied
        dec inv_n
        bne inv_countloop
inv_countdone

        lda #4
        sta msg_x
        lda #48
        sta msg_y
        lda #24
        sta box_w
        ldb inv_occupied
        addb #3                   ; +1 line for EXIT, +2 cells padding
        stb box_h
        jsr draw_box

        clr inv_line
        lda #64
        sta inv_liney
inv_drawloop
        lda #6
        sta msg_x
        lda inv_liney
        sta msg_y
        lda inv_cursor
        cmpa inv_line
        bne inv_nomark
        lda #'X'                  ; cursor marker -- see comment above
        jsr putglyph               ; on why not '>'
inv_nomark
        lda #8
        sta msg_x
        lda inv_liney
        sta msg_y

        lda inv_line
        cmpa inv_occupied
        beq inv_drawexit
        ldx #inv
        ldb inv_line
        abx
        lda ,x
        beq inv_drawexit           ; shouldn't happen -- safety net
        if TAPE_ROOMS
        jsr tape_slot_name         ; T0227 (tape_item_code.asm): A = inv slot value -> D = name.
                                   ; Finds the record in EITHER table (slot > 100 = actor_init_tape:
                                   ; the base-only lookup below read garbage for every tape item)
                                   ; and names it per record
        else
        deca                       ; frame lookup needs the actor's own
        ldb #ACTOR_STRIDE           ; record, not the inv[] slot value
        mul                         ; itself (which is index+1)
        addd #actor_ram
        tfr d,x
        lda 4,x                    ; frame
        jsr item_name_msg
        endif
        tfr d,x
        jsr prtmessage
        bra inv_nextline
inv_drawexit
        ldx #msg_inv_exit
        jsr prtmessage
inv_nextline
        lda inv_liney
        adda #8
        sta inv_liney
        lda inv_line
        inca
        sta inv_line
        cmpa inv_occupied
        bls inv_drawloop

inv_wait_release
        jsr fb_stablekeys
        anda #%00010011            ; UP(1)+DOWN(2)+SPACE(16)
        bne inv_wait_release
inv_wait_press
        jsr fb_stablekeys
        sta inv_k1
        anda #%00010011
        beq inv_wait_press

        lda inv_k1
        bita #1
        bne inv_up
        lda inv_k1
        bita #2
        bne inv_down
        bra inv_select

inv_up
        lda inv_cursor
        beq inv_up_wrap
        deca
        sta inv_cursor
        lbra inv_redraw
inv_up_wrap
        lda inv_occupied
        sta inv_cursor
        lbra inv_redraw

inv_down
        lda inv_cursor
        cmpa inv_occupied
        beq inv_down_wrap
        inca
        sta inv_cursor
        lbra inv_redraw
inv_down_wrap
        clr inv_cursor
        lbra inv_redraw

inv_select
        lda inv_cursor
        cmpa inv_occupied
        beq inv_close              ; EXIT selected

        ldx #inv
        ldb inv_cursor
        abx
        lda ,x
        sta drop_slot
        if TAPE_ROOMS
        jsr tape_drop_hook       ; T0230 (tape_talk_code.asm): droppingwhiskey X:5858
        endif

        lda inv_cursor
        sta inv_si
inv_slideloop
        lda inv_si
        cmpa #INV_SLOTS-1
        bhs inv_slidedone
        ldx #inv
        ldb inv_si
        abx
        lda 1,x
        sta ,x
        inc inv_si
        bra inv_slideloop
inv_slidedone
        ldx #inv
        ldb #INV_SLOTS-1
        abx
        clr ,x

        jsr play_drop            ; T0109: sndfx 11, dropobject
        jsr drop_to_world
        jsr box_reset            ; T0258 (D1): justexitinvent calls resetuproom BEFORE its trigger check
        jsr check_drop_trigger   ; T0105: X-ALL.TXT justexitinvent's own
                                  ; "CHECK DROPPING OBJECT BY TRIGGER"
        bra inv_fr
inv_close
        jsr box_reset            ; T0258 (D1): EXIT -> justexitinvent -> resetuproom
inv_fr
        jsr force_redraw       ; T0221 (was 8 bytes inline)
        rts

; --- state ----------------------------------------------------------
ai_n        fdb 0
da_n        fcb 0
da_p_col0   fcb 0
da_p_col1   fcb 0
da_p_y0     fcb 0
da_p_y1     fcb 0
ah_spr      fdb 0
ah_ax       fcb 0
ah_ay       fcb 0
ah_ar       fcb 0
ah_ab       fcb 0
ah_dl       fcb 0
ah_dr       fcb 0
ah_dt       fcb 0
tp_n        fcb 0
tp_slot     fcb 0
        if TAPE_ROOMS
tp_scan_phase fcb 0     ; T0234: 0 = scanning actor_ram, 1 = scanning
                         ; actor_init_tape -- see try_pickup's own note.
        endif
ii_i        fcb 0
drop_slot   fcb 0
pickup_timer fcb 0
inv_cursor  fcb 0
inv_occupied fcb 0
inv_line    fcb 0
inv_liney   fcb 0
inv_n       fcb 0
inv_k1      fcb 0
inv_si      fcb 0

inv         rmb INV_SLOTS   ; carried items, newest first; 0 = empty
inv_cap     fcb 3           ; usable slots (the bag would raise this to 4)

actor_ram   rmb ACTOR_COUNT*ACTOR_STRIDE

; croc_var_ptr: X -> the record for the buffer being drawn into.
croc_var_ptr
        lda draw_base
        cmpa #$40
        beq cvp_a
        ldx #croc_var_b
        rts
cvp_a
        ldx #croc_var_a
        rts

; --------------------------------------------------------------------
; T0057: coins. A THIRD interaction mechanism in the original, simpler
; than both actors and proximity triggers: `cointable` is 30 static
; `x,y,room` triples, `putcoinsinroom` draws frame 0 at each one
; belonging to the room being entered, and `pickupcoins` collects one
; by setting bit 7 of its ROOM byte. That flag trick is why coin_ram
; needs no separate "collected" array -- and why the room test below is
; just `cmpa cur_room`: a collected coin's room byte no longer equals
; any real room number.
;
; Coins never move, so they need no clear/save-under of their own --
; they are drawn like room placements, gated on the same damage rect,
; and re-appear after anything that forces a full redraw.
;
; T0062: gated on `coin_covered`, not just draw ORDER. The original
; comment here claimed drawing coins before actors was enough to hide
; room 52's coin under the removable railing -- true only if the
; covering actor is redrawn EVERY pass the coin is. `blit` only ORs ink
; on; it never clears. A pass where Dizzy's own movement touches the
; coin's damage rect without also touching the (unmoving) railing's --
; a perfectly normal thing to happen once he's walked away from both --
; draws the coin again with nothing there to cover it back up, and it
; shows through the railing's own gaps permanently. Real playtest
; screenshot caught it. `coin_covered` tests the coin's box against
; every LIVE actor's CURRENT position/sprite in this room, so it works
; regardless of redraw timing -- and for room 36's coin under the
; troll, it now genuinely tracks him: covered while he's parked, open
; the moment he tumbles and his position changes, closed again once he
; lands back. No more relying on his sprite happening to have enough
; ink over that exact spot.
; --------------------------------------------------------------------
draw_coins
        ldx #coin_ram
        lda #COIN_COUNT
        sta dc_n
dc_loop
        lda ,x
        cmpa cur_room
        bne dc_next
        lda 1,x                  ; pixel x -> column
        lsra
        lsra
        lsra
        cmpa dmg_col1
        bhs dc_next
        adda aspr_0_bpr
        inca                     ; +1 for a 4px-shifted spill
        cmpa dmg_col0
        bls dc_next
        ldb 2,x
        cmpb dmg_y1
        bhs dc_next
        addb aspr_0_h
        cmpb dmg_y0
        bls dc_next

        pshs x
        lda 1,x
        sta ov_ax
        lda 2,x
        sta ov_ay
        lda aspr_0_w
        sta ov_aw
        lda aspr_0_h
        sta ov_ah
        jsr coin_covered
        puls x
        tsta
        bne dc_next

        pshs x
        ldd #aspr_0_w
        std blit_ptr
        lda 1,x
        sta blit_x
        lda 2,x
        sta blit_y
        jsr blit
        puls x
dc_next
        leax COIN_STRIDE,x
        dec dc_n
        bne dc_loop
        rts

        if TAPE_ROOMS
; --------------------------------------------------------------------
; T0236: draw_coins_tape -- the tape-only region's own coin table
; (coin_init_tape, COIN_COUNT_tape). Reuses dc_loop's own body entirely
; (every branch in it reads X/COIN_STRIDE generically, no table-specific
; addressing) -- only the starting table base and count differ, same
; shape as draw_actors_tape re-entering da_loop above. Called from
; room36.asm's mainloop, gated on TAPE_ROOMS, straight after draw_coins
; itself.
;
; coin_covered (inside dc_loop) still only scans actor_ram (the BASE
; actor table), not actor_init_tape -- a tape-region coin overlapping a
; tape-region actor would draw uncovered. Checked every one of the 15
; tape coins against every wired tape actor's box (extracted/actors.json,
; both pixel_x/y): the base-room coins (22/67/76) only ever coincide with
; BASE actors, already handled by coin_covered as-is; of the tape-only-
; room coins, exactly ONE real coincidence exists -- room 73's coin sits
; at the SAME (96,72) pixel position as the windowmess pickupable
; (frame 204, T0234), both real, distinct entries in the original's own
; data (X-ALL.TXT cointable line 510 and the same room's pickupable both
; carry x=56,y=72). Undrawn coin-vs-actor z-order for that one case is a
; documented simplification, not fixed this round -- same class as
; T0234's own "known limitation" notes.
; --------------------------------------------------------------------
draw_coins_tape
        ldx #coin_init_tape
        lda #COIN_COUNT_tape
        sta dc_n
        lbra dc_loop
        endif

; pickup_coins: A != 0 if a coin was collected this call. Called from
; try_pickup, i.e. only on the pickup key -- the original's
; `pickupcoins` opens with the same `ld a,(pickup) / and a / ret z`
; gate, so coins are NOT vacuumed up by walking over them.
pickup_coins
        ldx #coin_ram
        lda #COIN_COUNT
        sta pc_n
pc_loop
        lda ,x
        cmpa cur_room
        bne pc_next

        ; T0062: a covered coin isn't collectible either -- otherwise
        ; you could grab it by standing where it invisibly sits, before
        ; ever seeing it or picking up the railing on top of it.
        pshs x
        lda 1,x
        sta ov_ax
        lda 2,x
        sta ov_ay
        lda aspr_0_w
        sta ov_aw
        lda aspr_0_h
        sta ov_ah
        jsr coin_covered
        puls x
        tsta
        bne pc_next

        lda 1,x
        sta ah_bx
        lda 2,x
        sta ah_by
        lda aspr_0_w
        sta ah_bw
        lda aspr_0_h
        sta ah_bh
        pshs x
        jsr aabb_hit
        puls x
        tsta
        bne pc_take
pc_next
        leax COIN_STRIDE,x
        dec pc_n
        bne pc_loop
        clra
        rts
pc_take
        lda ,x
        ora #$80                 ; collected, the original's `set 7,(ix+2)`
        sta ,x
        inc coins
        jsr play_chirp           ; T0255: X-ALL pickupcoins: `ld a,5 / call starttune` BEFORE youfoundcoinmess
        jsr msg_begin
        ldx #msg_foundcoin
        jsr msg_box_done       ; T0221 (was 9 bytes inline)
        lda #1
        rts

        if TAPE_ROOMS
; --------------------------------------------------------------------
; T0236: pickup_coins_tape -- same table swap as draw_coins_tape, for
; the collect path. try_pickup calls this right after pickup_coins,
; only when the base pass found nothing (A=0) -- the two passes can
; never both fire for one keypress, matching try_pickup's own base/tape
; actor two-pass shape (T0234).
; --------------------------------------------------------------------
pickup_coins_tape
        ldx #coin_init_tape
        lda #COIN_COUNT_tape
        sta pc_n
        lbra pc_loop
        endif

; --------------------------------------------------------------------
; T0062: coin_covered -- A != 0 if the box (ov_ax,ov_ay,ov_aw,ov_ah),
; already set by the caller, overlaps any LIVE actor currently in
; cur_room. Used by draw_coins and pickup_coins so a coin's visibility
; and its collectibility are the SAME test, computed fresh every call
; from each actor's actual current position rather than assumed from
; draw order (see draw_coins' own comment for why draw order alone
; isn't enough with an OR-only blit).
;
; Deliberately actor-vs-coin, not damage-rect-vs-coin: the rat and troll
; both move under their own power, outside Dizzy's damage rect, so a
; test keyed on damage rect would miss exactly the moving case this
; exists for (room 36's coin under the tumbling troll).
; --------------------------------------------------------------------
coin_covered
        ldx #actor_ram
        lda #ACTOR_COUNT
        sta cc_n
cc_loop
        lda ,x
        cmpa cur_room
        bne cc_next
        pshs x
        lda 4,x                  ; frame
        jsr actor_sprite
        puls x
        cmpu #0
        beq cc_next
        lda ,u                    ; width
        sta ov_bw
        lda 1,u                   ; height
        sta ov_bh
        lda 2,x
        sta ov_bx
        lda 3,x
        sta ov_by
        pshs x
        jsr boxes_overlap
        puls x
        tsta
        bne cc_covered
cc_next
        leax ACTOR_STRIDE,x
        dec cc_n
        bne cc_loop
        clra
        rts
cc_covered
        lda #1
        rts

; --------------------------------------------------------------------
; boxes_overlap: standard top-left-anchored AABB-vs-AABB test (NOT
; Dizzy's feet-anchored one -- aabb_hit stays separate on purpose,
; since coin/actor y is a sprite top like every other placement).
; Box A = (ov_ax,ov_ay,ov_aw,ov_ah), box B = (ov_bx,ov_by,ov_bw,ov_bh),
; both set by the caller. A != 0 if they overlap.
; --------------------------------------------------------------------
boxes_overlap
        lda ov_ax
        adda ov_aw
        cmpa ov_bx
        bls bo_no                 ; a_right <= b_x
        lda ov_bx
        adda ov_bw
        cmpa ov_ax
        bls bo_no                 ; b_right <= a_x
        lda ov_ay
        adda ov_ah
        cmpa ov_by
        bls bo_no                 ; a_bottom <= b_y
        lda ov_by
        adda ov_bh
        cmpa ov_ay
        bls bo_no                 ; b_bottom <= a_y
        lda #1
        rts
bo_no
        clra
        rts

; T0066: what each framebuffer last drew for the crocodile (frame id
; with the facing flag in bit 7), 255 = "nothing yet". Same shape as
; fire_var_a/b -- the two buffers alternate, so each needs its own
; record or one of them silently keeps a stale sprite.
croc_var_a  fcb 255
croc_var_b  fcb 255

dc_n        fcb 0
pc_n        fcb 0
cc_n        fcb 0
        if TAPE_ROOMS
ud1_n           fcb 0
ud1_par         fcb 0
completedgame   fcb 0     ; T0236: X-ALL.TXT's own name/reset-to-0 shape
                            ; (new_game's own equivalent of resetlives'
                            ; `ld (completedgame),a` with a=0 -- see
                            ; new_game's own comment, room36.asm)
        endif
ov_ax       fcb 0
ov_ay       fcb 0
ov_aw       fcb 0
ov_ah       fcb 0
ov_bx       fcb 0
ov_by       fcb 0
ov_bw       fcb 0
ov_bh       fcb 0
coin_ram    rmb COIN_COUNT*COIN_STRIDE

