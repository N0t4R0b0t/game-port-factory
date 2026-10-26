; T0239: tape-only CODE, assembled into the tape-only region (after
; msg_data_tape.asm, inside room36.asm's `if TAPE_ROOMS`), NOT into the
; resident low image: the resident title-hole budget (the holes the
; title screen is packed into) was down to ~140 bytes spare and
; update_hawk alone overflowed it. This region is delivered raw at its
; real address (T0230), executes like any RAM, and every symbol it
; touches is a plain resident label, resolved in the same lwasm pass.
; Plain hand-written asm, not a DTE source (no text in it anyway).
; update_switch1 (T0238) was moved here from resident actors.asm in T0239
; for the same title-hole reason.

; --------------------------------------------------------------------
; T0238: update_switch1 -- X-ALL.TXT switchrou1 (room 94, ROU_SWITCH1,
; frame 122) -- daisylifthere's own one-way "press to lower" switch.
; Every pass: the lift's var1 is forced to 0 first (X-ALL's own
; unconditional `xor a/ld (daisylifthere+var1),a`); once the lift's
; own movey has reached 100 (of its 56..120 travel), the original
; returns immediately and leaves it off for good (`cp 100/ret nc`) --
; there is no way back up. Otherwise, while Dizzy stands on the switch
; box (`collidewithdizzy16`, actor_hit's own equivalent here), var1 is
; set to 1 (descending); step off and it holds at 0 again next pass.
; T0255: the switch's mirrored-colour redraw (resetmachines, X-ALL.TXT ~2932)
; IS ported now: the record's colour bit 7 follows "Dizzy stands on it" and
; draw_actors draws a bit-7 lever mirrored (tape_static_mirror).
update_switch1
        lda cur_room
        cmpa #94
        bne us1_ret
        jsr ud94_daggers         ; T0227 (tape_item_code.asm)
        ; T0255: the switch, Daisy and the lift all have delay 2 (movingdata z62/z63/z64): the delay counters of the three
        ; advance together, once per actor tick in this room, and each routine runs when its counter reaches 2.  d94 = the
        ; parity (block D, armorog_lifts_dagger_code.asm); update_lifts ran EARLIER this tick and saw it before this flip.
        lda d94
        eora #1
        sta d94
        bne us1_ret              ; new value 1 = the previous was 0 = this tick is the first of the pair: skip
        ldd #0
        std us1_lift
        std us1_sw
        ldy #actor_init_tape
        lda #ACTOR_COUNT_tape
        sta us1_n
us1_loop
        lda ,y
        cmpa cur_room
        bne us1_next
        lda 1,y
        cmpa #ROU_LIFT
        bne us1_chksw
        sty us1_lift
        bra us1_next
us1_chksw
        cmpa #ROU_SWITCH1
        bne us1_next
        sty us1_sw
us1_next
        leay ACTOR_STRIDE,y
        dec us1_n
        bne us1_loop
        ldy us1_lift
        cmpy #0
        beq us1_done
        clr 5,y                  ; lift var1 = 0 (forced every pass)
        lda 3,y                  ; lift's movey
        cmpa #100
        bhs us1_done             ; stuck past 100 -- off forever
        ldy us1_sw
        cmpy #0
        beq us1_done
        jsr actor_hit
        ldy us1_sw               ; T0255: resetmachines -- the lever is drawn mirrored (colour bit 7) while it is pressed
        ldb 7,y
        andb #$7f
        tsta
        beq us1_lvr
        orb #$80
us1_lvr stb 7,y
        tsta
        beq us1_done
        ldy us1_lift
        lda #1
        sta 5,y
us1_done
        jmp ud94_daisy           ; T0228: Daisy rides this lift / the meeting (tape_daisy_code.asm)
us1_ret
        rts
us1_n    fcb 0
us1_lift fdb 0
us1_sw   fdb 0

; --------------------------------------------------------------------
; T0239: update_hawk -- X-ALL.TXT resethawk/hawkrou (room 49, ~2848).
; Record (8 bytes): x,y px, frame, v1 = var1 bit0 (diving), v2 = the
; source's oldmovefrm (0..127). Acts every 2nd pass (the record's
; delay=2, same approach as update_armorog's ua_dc). Patrol: frame
; 96+((n&3) or 2), n=(n+1)&127, a=n>>1 folded into a triangle 0..32,
; x = a*4+32 px (movex=a+40 raw, (raw-32)*4). While 72<=x<128 px (raw
; 50..63) and Dizzy is inside the strip (x+8,52,16,120) it dives:
; frame 97, var1=1. Dive: x tracks Dizzy's x, y+=8 per act; touching
; it kills (msg_killedbyhawk). Room entry resets y=52, var1=0, detected
; with room_load_seq like update_armorog.
; --------------------------------------------------------------------
update_hawk
        lda cur_room
        cmpa #49
        bne uh_ret
        ldy #actor_init_tape
        lda #ACTOR_COUNT_tape
        sta uh_n
uh_find
        lda ,y
        cmpa #49
        bne uh_nx
        lda 1,y
        cmpa #ROU_HAWK
        beq uh_have
uh_nx
        leay ACTOR_STRIDE,y
        dec uh_n
        bne uh_find
uh_ret
        rts
uh_have
        lda room_load_seq
        cmpa uh_seq
        beq uh_noreset
        sta uh_seq
        lda #52
        sta 3,y                  ; resethawk: movey=52, var1=0 ...
        clr 5,y
        bra uh_step              ; ... then joinresthawk: one animation step NOW; the delay counter is not touched (T0258, D1)
uh_noreset
        inc uh_dc
        lda uh_dc
        cmpa #2
        lblo uh_ret
        clr uh_dc
uh_step
        lda 5,y
        anda #1
        bne uh_dive
        lda 6,y
        anda #3
        bne uh_f
        lda #2
uh_f
        adda #96
        sta 4,y
        lda 6,y
        inca
        anda #127
        sta 6,y
        lsra
        cmpa #32
        blo uh_okx
        nega
        adda #64
uh_okx
        asla
        asla
        adda #32
        sta 2,y
        cmpa #72
        lblo uh_ret
        cmpa #128
        lbhs uh_ret
        adda #8
        sta ah_bx
        lda #52
        sta ah_by
        lda #16
        sta ah_bw
        lda #120
        jsr aabb_test
        lbeq uh_ret
        lda #1
        sta 5,y
        lda #97
        sta 4,y
        rts
uh_dive
        lda dizzy_x
        anda #$fc
        sta 2,y
        lda 3,y
        adda #8
        sta 3,y
        jsr actor_hit
        tsta
        lbeq uh_ret
        ldx #msg_killedbyhawk
        jmp kill_dizzy_msg
uh_n    fcb 0
uh_dc   fcb 0
uh_seq  fcb 0


; --------------------------------------------------------------------
; T0239: DRAGON, room 40 (X-ALL.TXT dragonhere1 / dragonrou ~2566 /
; trytostartbreathing ~2540 / proxegg ~3440). Geometry is identical to
; room 54's dragon (same raw x=68,y=152, frames 109/110/111), so the
; resident draw_dragon, dragon_necky and block D's dragon_flames are
; reused as they are; this is the per-room update (a near copy of
; update_dragon, which is hard-gated to room 54 and finds its actor in
; actor_ram) plus the three things that differ:
;
;  - FIRE: in room 54 the breath is a random 5/256 per tick; in any other
;    room `trytostartbreathing` only starts one if goldenegghere1's room
;    is 255 (the nest egg has been TAKEN) and then starts it every tick it
;    is not already breathing. With the egg in the nest the dragon only
;    swings its head -- and still kills on contact (collidewithdizzy16
;    runs before the fire test, regardless).
;  - SLEEP: no sleeping potion here -- proxegg: dropping the egg back in
;    the nest box (raw (54,150,4,20) -> px (88,150,16,20)) sets this
;    dragon's var1 to 255 (it retracts to -8 and stops) and shows
;    puteggbackmess. The port's dragon_asleep/dragon_swing are single
;    globals (one dragon when they were written), so dragon_swap keeps one
;    (asleep,swing) pair per dragon and swaps them on room change; the
;    breath (dragon_fire) is shared, as the original's
;    `breathingfire` is.
;  - find the egg: two records have frame 10 (room 93's egg too), and the
;    live egg's room byte becomes 255 when carried, so it is found once by
;    (room 40, frame 10) in the PRISTINE template and its slot cached.
; --------------------------------------------------------------------
DR_NEST_X   equ 88
DR_NEST_Y   equ 150
DR_NEST_W   equ 16
DR_NEST_H   equ 20

; dragon_swap: keep dragon_asleep/dragon_swing per dragon (0 = room 54,
; 1 = room 40). Called every pass before update_dragon.
dragon_swap
        lda cur_room
        ldb #1
        cmpa #40
        beq dsw_have
        clrb
        cmpa #54
        bne dsw_ret
dsw_have
        cmpb dr_owner
        beq dsw_ret
        pshs b
        ldx #dr_slots              ; save the outgoing dragon's state (T0255: 3 bytes -- the swing's delaycounter is per dragon too)
        lda dr_owner
        ldb #3
        mul
        leax b,x
        lda dragon_asleep
        sta ,x
        lda dragon_swing
        sta 1,x
        lda dragon_delay
        sta 2,x
        puls b
        stb dr_owner
        ldx #dr_slots              ; load the incoming one
        tfr b,a
        ldb #3
        mul
        leax b,x
        lda ,x
        sta dragon_asleep
        lda 1,x
        sta dragon_swing
        lda 2,x
        sta dragon_delay
dsw_ret
        rts

; tape_state_reset: new_game (reset_tape_actors' tail jump). T0216: the
; river's waterheight is a global byte the original zeroes in resetmoving
; (X-ALL.TXT ~1820); falls through into dragon_reset (T0239), whose rts
; returns to reset_tape_actors' caller.
tape_state_reset
        jsr bean_reset           ; T0223: shopkeeper timer/junk counter, stalk (tape_bean_code.asm)
        clr waterheight
        clr uh_dc                ; T0258: hawk's delaycounter (reseteach at game start)
        clr dz_talks             ; T0218: Dozy (below)
        clr tt_dylan             ; T0229: Dylan/Doug's talkbefore (below)
        clr tt_doug
        clr drunk                ; T0230: X:6771
        ldy #DZ_FLOAT
        lda #255
        sta ,y                   ; the float is not in the world ...
        clr 5,y                  ; ... and not floating
; dragon_reset: new_game (called from reset_tape_actors).
dragon_reset
        clr dr_owner
        ldd #0
        std dr_slots
        std dr_slots+2
        std dr_slots+4
        clr dr_egg_slot_ok
        rts

update_dragon40
        lda cur_room
        cmpa #40
        lbne ud40_ret
        lda dragon_asleep
        beq ud40_awake
        lda dragon_swing
        cmpa #-8
        lbeq ud40_ret               ; retracted for good
ud40_awake
        ldy #actor_init_tape
        lda #ACTOR_COUNT_tape
        sta ud40_n
ud40_find
        lda ,y
        cmpa #40
        bne ud40_nx
        lda 1,y
        cmpa #ROU_DRAGON
        beq ud40_found
ud40_nx
        leay ACTOR_STRIDE,y
        dec ud40_n
        bne ud40_find
        rts
ud40_found
        tfr y,x
        ; T0255: trytostartbreathing first (room 40: the nest egg is gone), then the swing/head, then the flames --
        ; the same order as update_dragon (dragon_code.asm).
        tst dragon_asleep
        bne ud40_head
        tst dragon_fire
        bne ud40_head
        pshs x
        bsr ud40_trystart
        puls x
ud40_head
        jsr dragon_head          ; T0254: the swing/head/hit part is update_dragon's (dragon_code.asm)
        tst dragon_asleep
        bne ud40_ret
        tst dragon_fire
        beq ud40_ret
        jsr dragon_flames
ud40_ret
        rts

; ud40_trystart: not breathing: start only if the nest egg has been taken
ud40_trystart
        tst dr_egg_slot_ok
        bne ud40_egg_known
        ldx #actor_init_tape_template
        clrb
ud40_egg_scan
        lda ,x
        cmpa #40
        bne ud40_egg_nx
        lda 4,x
        cmpa #10
        beq ud40_egg_got
ud40_egg_nx
        leax ACTOR_STRIDE,x
        incb
        cmpb #ACTOR_COUNT_tape
        blo ud40_egg_scan
        rts                         ; no egg record (cannot happen)
ud40_egg_got
        stb dr_egg_slot
        inc dr_egg_slot_ok
ud40_egg_known
        lda dr_egg_slot
        ldb #ACTOR_STRIDE
        mul
        ldx #actor_init_tape
        leax d,x
        lda ,x
        cmpa #255
        bne ud40_ret                ; egg still in the nest: no breath
        lda #1
        sta dragon_fire
        jsr play_breath
        rts

; cdt_egg: check_drop_trigger's frame-10 branch (X = the dropped item).
; Only room 40's nest box counts (room 93 has an egg too).
cdt_egg
        lda cur_room
        cmpa #40
        lbne cdt_done
        ; T0235: only the ROOM-93 egg carries proxegg (X-ALL.TXT goldenegghere);
        ; the nest egg (goldenegghere1, room 40) has no prox pointer, so
        ; dropping it does nothing. Slot -> pristine template room byte
        ; (the live byte is 255 while carried).
        lda actor_init_tape_template-actor_init_tape,x
        cmpa #93
        lbne cdt_done
        lda #DR_NEST_X
        sta ah_bx
        lda #DR_NEST_Y
        sta ah_by
        lda #DR_NEST_W
        sta ah_bw
        lda #DR_NEST_H
        jsr aabb_test
        lbeq cdt_done
        lda #1
        sta dragon_asleep
        jsr msg_begin
        ldx #msg_puteggback
        jsr msg_box_done
        rts

ud40_n          fcb 0
dr_owner        fcb 0
dr_slots        fcb 0,0,0,0,0,0
dr_egg_slot     fcb 0
dr_egg_slot_ok  fcb 0

; --------------------------------------------------------------------
; T0216: ROOM 48's RIVER -- X-ALL.TXT waterheight (2089), addtowater
; (2097), proxrock/proxrockrou (2816), logrou (2831).
;
;  - waterheight (0, +6 per rock pushed in, max 18 = 3 rocks) is reset by
;    tape_state_reset above.
;  - addtowater in room 48 draws the water at y = 168-waterheight and
;    STRETCHES it to 3 tiles 8 raw units (32 px) apart: x = 80,112,144.
;    Each tile is a waterlist entry, so the drown box follows the drawn
;    water. The room's own packed data holds ONE tile at (80,184) (the
;    roompack trigger tile, hidden under the border): update_log48
;    repoints room_water_ptr/count at tide_list every pass in room 48, so
;    the shared room48_data.asm and the -run build are untouched.
;  - logrou: var1=(var1+1)&3 every 4th pass (the record's delay 4);
;    b=var1 (2 if 0); y = 162-waterheight+b. The record is routine 6
;    (ROU_LOG, colour 10: bit 6 clear = solid), so build_solid_actors'
;    tape pass already makes it a platform; the ground scan carries
;    Dizzy with it. draw_actors routes it through the rat's save-under
;    (a moving sprite) -- see actors.asm.
; --------------------------------------------------------------------
waterheight     fcb 0
tide_list       fcb 80,168,112,168,144,168
ul48_n          fcb 0
ul48_seq        fcb 0
ul48_dc         fcb 0

update_log48
        lda cur_room
        cmpa #48
        bne ul48_ret
        ldb waterheight
        negb
        addb #168
        stb tide_list+1
        stb tide_list+3
        stb tide_list+5
        ldx #tide_list
        stx room_water_ptr
        lda #3
        sta room_water_count
        ldy #actor_init_tape
        lda #ACTOR_COUNT_tape
        sta ul48_n
ul48_find
        ldd ,y
        cmpd #48*256+ROU_LOG
        beq ul48_have
        leay ACTOR_STRIDE,y
        dec ul48_n
        bne ul48_find
ul48_ret
        jmp update_dozy          ; T0218: chained here, saves a resident call site
ul48_have
        lda room_load_seq        ; T0255: X-ALL resetlog IS the log's step: every entry into the room runs one (the
        cmpa ul48_seq            ; delay counter is not touched), so the cycle is one step ahead of the delay-4 beat
        beq ul48_notnew
        sta ul48_seq
        bra ul48_dostep
ul48_notnew
        inc ul48_dc
        lda ul48_dc
        anda #3
        bne ul48_nostep
ul48_dostep
        lda 5,y
        inca
        anda #3
        sta 5,y
ul48_nostep
        lda 5,y
        bne ul48_b
        lda #2
ul48_b
        adda #162
        suba waterheight
        sta 3,y
        rts

; cdt_rock: check_drop_trigger's frame >= 136 branch (A = dropped frame,
; X = its record). proxrockrou: a rock (frames 136/138/139) dropped in
; room 48's box raw (72,80,10,30) -> px (160,80,40,30) goes INTO the river:
; room=48, waterheight+=6, x=(76-waterheight) raw -> 176-4*wh px, y=176,
; rockinwatermess.
cdt_rock
        cmpa #136
        beq cr_ok
        cmpa #138
        beq cr_ok
        cmpa #139
        lbne cdt_done
cr_ok
        lda cur_room
        cmpa #48
        lbne cdt_done
        lda #160
        sta ah_bx
        lda #80
        sta ah_by
        lda #40
        sta ah_bw
        lda #30
        jsr aabb_test
        lbeq cdt_done
        lda #48
        sta ,x
        lda waterheight
        adda #6
        sta waterheight
        asla
        asla
        nega
        adda #176
        sta 2,x
        lda #176
        sta 3,x
        jsr msg_begin
        ldx #msg_rockinwater
        jmp msg_box_done


; --------------------------------------------------------------------
; T0218: DOZY, room 45 -- X-ALL.TXT dozyhere (1661), dozytalking (613),
; dozyrou (2411), dozyfloathere (1665), resetdozyfloat/dozyfloatrou (3230).
;
;  - Talking is pickupablerou -> talkingtopeople (frames 32..39, see
;    actors.asm's tp_take). talkbefore[0] counts the talks: the 1st runs
;    `dozytalking` (a long conversation; its leading `defw
;    sleepingpotionhere+room` MATERIALISES the potion in the room you
;    talked in), talks 2..4 run dozyrou with count 2..4 = kickdozyagainmess,
;    talk 5 = pushdozymess: dozyhere.room=255 and dozyfloathere.var1=255.
;    T0220: the 1st talk shows msg_dozytalking (8 boxes) from the
;    TAPE_LOW_REGION slot (msg_data_tape_low.asm).
;    A 6th talk would do nothing (`ret nc`) but he is gone by then.
;    dz_talks is that count; dozy_talk is called from tp_take with Y = the
;    dozyhere record and returns X = the message stream.
;  - The records are consecutive in the table (dozyhere, dozyfloathere):
;    the float is Y+ACTOR_STRIDE. The potion's slot and the float's are
;    fixed indices (DZ_POTION/DZ_FLOAT); harness/tape_dozyfloat.lua
;    asserts they are what they should be.
;  - dozyfloatrou runs every pass (delay 0), only in room 45 (domoving):
;    t=var1; a=(t-1)&3; if a==0 { x-=1 raw (4 px); a=4 }; var1=a;
;    y = 139 + (1,0,1,2 .. i.e. (a-1) with 3 -> 1). 255 starts it at
;    bob 1, 0, then [x--, 1] [2] [1] [0] repeating. The original ends when
;    raw x < 28; raw 32 is the left screen edge (port px = 4*(raw-32)), and
;    the port cannot draw a sprite partly off the left edge, so it ends at
;    px 0 instead (var1=0 AND room=255, see below).
;  - Colour 95 has bit 6 (dull): build_solid_actors skips it, so the float is
;    only a picture, not a platform (the original's attribute-based solidity
;    makes a dull-attribute actor non-solid; the log, colour 10, is solid).
;  - Not in the world until pushed: tape_state_reset puts its room at 255
;    (the record's own room is 45 with var1 0, which the original just
;    never prints); the push puts it back to 45. Drawn by draw_actors'
;    ROU_DOZYFLOAT hook (always-redraw + the rat's save-under).
; --------------------------------------------------------------------
; T0223: +3 slots (shopkeeper x2, bean sit between the hawk and the egg, by
; original slot order: rows 1..3 of the table)
DZ_POTION       equ actor_init_tape+5*ACTOR_STRIDE
DZ_FLOAT        equ actor_init_tape+11*ACTOR_STRIDE
DZ_Y            equ 139
dz_talks        fcb 0

dozy_talk
        lda dz_talks
        inca
        sta dz_talks
        ldx #msg_kickdozy
        cmpa #5
        beq dt_push
        cmpa #1
        bne dt_ret
        lda cur_room
        sta DZ_POTION            ; sleepingpotionhere+room := roomno
        ldx #msg_dozytalking     ; T0220: the original's 8-box conversation
dt_ret
        rts
dt_push
        lda #255
        sta ,y                   ; dozyhere.room = 255
        sta ACTOR_STRIDE+5,y     ; dozyfloathere.var1 = 255
        lda #45
        sta ACTOR_STRIDE,y       ; into the world (room 45)
        ldx #msg_pushdozy
        rts

update_dozy
        lda cur_room
        cmpa #45
        bne dzu_ret
        ldy #DZ_FLOAT
        lda 5,y
        beq dzu_ret
        deca
        anda #3
        bne dz_still
        lda 2,y
        suba #4
        sta 2,y                  ; x -= 1 raw
        lda #4
dz_still
        sta 5,y
        deca
        cmpa #3
        bne dz_bob
        lda #1
dz_bob
        adda #DZ_Y
        sta 3,y
        tst 2,y
        bne dzu_ret
        clr 5,y                  ; off the left edge: gone
        lda #255
        sta ,y
        jmp force_redraw         ; erase the last frame (tail call)
dzu_ret
        jmp update_shop          ; T0223: chained again (tape_bean_code.asm); its rts returns to mainloop
