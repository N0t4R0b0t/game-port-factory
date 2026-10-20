; --------------------------------------------------------------------
; logic_low.asm -- T0124: per-room behaviour routines (Armorog, the lifts).
;
; Assembled at $7800 -- the gap between framebuffer B and nibswap, empty
; since T0123 moved actor_data into the packed image -- not in the $0100
; "low" region the name still says: that region ends at start:'s $0E00, and
; this code pushed it 131 bytes past it (now guarded in room36.asm). $0E00-
; $4000 code+data is full too. Reached only by absolute jsr/ldx, so where it
; lives is arbitrary; its spare stays a load-time hole for the title
; (tools/title_holes.py measures the block).
; --------------------------------------------------------------------

; --------------------------------------------------------------------
; T0123: room 50's ARMOROG. X-ALL.TXT `armorogrou` / `resetarmorog`
; (~2436), states in the actor's own v1 like the source's var1:
;
;   0 asleep     wakes when Dizzy enters the box (64,125,12,40) raw ->
;                (128,125,48,40): y=155, frame 103, countdown 20
;   1 countdown  20 active ticks (the source keeps it in oldmovex; here v2)
;   2 running    +1 unit (4px) and frame 102<->103 per active tick. If
;                Dizzy is down at y>=150, or the BONE lies in room 50 at
;                raw x>=80,y>=140 (pixel x>=192), he runs for the den;
;                otherwise he stops at raw x 62 (120) and
;   3 guards     there, forever.
;   4 fed        reached the den (raw 78 = 184): faces the other way
;                (colour bit 7), y=156, the bone vanishes and "[X-ALL.TXT line 884] [X-ALL.TXT line 885]" -- unless Dizzy died on the way,
;                in which case he just resets.
;
; Touching him kills in every state (`collidewithdizzy16` first thing).
; delayrou gives him delay 2: all of the above runs every 2nd tick.
; resetarmorog runs from enterroom -- respawns included -- and puts him
; back to sleep at the start unless he is already fed.
;
; Verified against the running original with harness/zx_film.lua logging
; his movingdata record: wakes as Dizzy reaches raw x 42 walking in from
; 51, countdown ~110 frames, then x 54 -> 77 one unit per 2 ticks with the
; frames alternating, catching a Dizzy who stood on the floor.
; --------------------------------------------------------------------
ARM_START_X     equ 88
ARM_WAKE_X      equ 128
ARM_WAKE_Y      equ 125
ARM_WAKE_W      equ 48
ARM_WAKE_H      equ 40
ARM_DEN_X       equ 184
ARM_GUARD_X     equ 120
ARM_BONE_FRAME  equ 6

; T0162: update_armorog moved to target/armorog_lifts_dagger_code.asm,
; staged to CODE_DEST (block D) -- same reasoning as
; update_crocodile/update_portcullis (croc_portcullis_code.asm). Its
; own call site (room36.asm mainloop's `jsr update_armorog`) is
; unchanged; staged_syms.asm resolves the symbol. Covered by
; harness/actorlife.lua's armorog assertion.

; --------------------------------------------------------------------
; T0124: LIFTS. X-ALL.TXT `liftrou` / `resetlift` (~3053).
;
; Four (lift, machine, key) triples in the movingdata table; a key dropped
; in its proximity box in room 56 turns its machine on and sets bit 0 of
; its lift's var1 (check_drop_trigger). Of the four, only key 1 (room 85)
; and its lift (room 71) are in this build; room 56's own lift belongs to
; key 4, in unbuilt room 48, and stays off.
;
; A running lift moves 1px per tick (delay 1) between its top and bottom,
; pausing 50 ticks at each end (the source's oldmovex/oldmovey/oldmovefrm;
; here per-room constants and v2). If Dizzy is inside the shaft box
; (x, y-2, 32, 48): touching its top 2 rows kills him ("TRAPPED [X-ALL.TXT line 1004] [X-ALL.TXT line 1005]"); otherwise, unless he stands still within 12px of
; the lift's left edge, the lift pauses 2 ticks and every 64th such tick
; shows "[X-ALL.TXT line 957] [X-ALL.TXT line 958]".
;
; Measured in the original (zx_film, room 71, lift switched on): y 56->112
; one pixel per tick, ~50 ticks' pause at each end, and back.
; --------------------------------------------------------------------
; T0162: update_lifts moved to target/armorog_lifts_dagger_code.asm,
; staged to CODE_DEST (block D) -- same reasoning as
; update_crocodile/update_portcullis (croc_portcullis_code.asm). Its
; own call site (room36.asm mainloop's `jsr update_lifts`) is
; unchanged; staged_syms.asm resolves the symbol. ul_bounds below
; stays here, resident -- draw_lift and room36.asm's
; build_solid_actors both call it too. Covered by harness/keylift.lua.
ul_bounds
        cmpa #71
        if TAPE_ROOMS
        bne ulb_40chk
        else
        bne ulb_56
        endif
        lda #56
        sta ul_top
        lda #112
        sta ul_bot
        lda #48
        sta ul_orig
        rts
        if TAPE_ROOMS
; T0238: rooms 40/88/94 -- their own lift bounds, X-ALL.TXT movingdata
; (oldmovex=top/oldmovey=bot, origy=rope origin), same source the
; 71/56 cases above were already transcribed from. Room 40's lift
; rides along because room 40 is already in actor_data_tape's own
; --actor-rooms list (T0234's pickupables); see regen_art.sh's own
; T0238 comment for why it is kept rather than excluded.
ulb_40chk
        cmpa #40
        bne ulb_88chk
        lda #56
        sta ul_top
        lda #134
        sta ul_bot
        lda #56
        sta ul_orig
        rts
ulb_88chk
        cmpa #88
        bne ulb_94chk
        lda #56
        sta ul_top
        lda #136
        sta ul_bot
        lda #48
        sta ul_orig
        rts
ulb_94chk
        cmpa #94
        bne ulb_56
        lda #56
        sta ul_top
        lda #120
        sta ul_bot
        lda #48
        sta ul_orig
        rts
        endif
ulb_56
        lda #104
        sta ul_top
        lda #140
        sta ul_bot
        lda #104
        sta ul_orig
        rts

; --------------------------------------------------------------------
; draw_lift: Y = lift actor, cb_spr/cb_x/cb_y already set by draw_actors.
; Called every pass, on or off. The source draws the top (frame 125) in
; OVERWRITE mode from its start height down to its y -- frame 125's top row
; is the hook, so that leaves a rope -- and the bar Dizzy rides (frame 126)
; 40px lower in XOR. Here: the rope rows written directly (frame 125's row
; 0 is $01,$80 in its middle two bytes), then both frames overwritten, with
; two rows cleared beside each so a 2px-per-buffer move leaves nothing.
; --------------------------------------------------------------------
draw_lift
        sty dl_act
        lda 2,y
        lsra
        lsra
        lsra
        sta dl_col
        lda 3,y
        sta dl_y
        lda cur_room
        jsr ul_bounds
        ldb ul_orig
dl_rope
        cmpb dl_y
        bhs dl_ropedone
        stb dl_row
        jsr dl_rowx               ; X = row dl_row, column dl_col
        clr ,x
        lda #$01
        sta 1,x
        lda #$80
        sta 2,x
        clr 3,x
        ldb dl_row
        incb
        bra dl_rope
dl_ropedone
        lda dl_y                  ; two rows under the top frame
        adda #10
        jsr dl_clr2
        ldy dl_act
        jsr clear_and_blit        ; frame 125 at y (cb_* from draw_actors)
        lda dl_y                  ; the bar 40 below: clear around it, draw
        adda #38
        jsr dl_clr2
        lda dl_y
        adda #40
        adda aspr_126_h
        jsr dl_clr2
        ldd #aspr_126_w
        std cb_spr
        ldy dl_act
        lda 2,y
        sta cb_x
        lda dl_y
        adda #40
        sta cb_y
        jsr clear_and_blit
        ldy dl_act
        rts

; dl_rowx: X = draw_base + dl_row*32 + dl_col
dl_rowx
        lda #FBWIDTH
        ldb dl_row
        mul
        addd draw_base
        addb dl_col
        adca #0
        tfr d,x
        rts
; dl_clr2: A = first row; clears that row and the next, 4 bytes at dl_col
dl_clr2
        sta dl_row
        jsr dl_rowx
        ldb #2
dlc_row
        clr ,x
        clr 1,x
        clr 2,x
        clr 3,x
        leax FBWIDTH,x
        decb
        bne dlc_row
        rts

; T0162: ul_n/ul_slot/ul_obstruct/ul_y/ul_top/ul_bot moved to
; target/armorog_lifts_dagger_code.asm with update_lifts -- see that
; file's own header. ul_orig stays here: draw_lift and room36.asm's
; build_solid_actors both read it, set by ul_bounds above (also
; resident).
ul_orig     fcb 0
dl_act      fdb 0
dl_col      fcb 0
dl_y        fcb 0
dl_row      fcb 0

; --------------------------------------------------------------------
; T0125: THE WELL (rooms 55 -> 39 -> 23 and back). X-ALL.TXT's `newroom`
; special cases (~1235-1320), run from rt_vertical once room_transition_up/
; down have set rt_newroom and rt_arrive (goneup/gonedown's y).
;
;   into 39 from anywhere, or down out of 23 (room 7 is never a room):
;       fallenoutof23 -- lastroom = here, newroom = 39, an ordinary tumble:
;       dy 4, no steering (well_mode 1)
;   down out of 39 (toward 23): flipandsettumble -- upsidedown toggles, and
;       Dizzy comes back into 39 at y=180 in sequence 8 with dy pinned at -6
;       (well_mode 2): drawn flipped, falling code reads as rising
;   up out of 39: settojumpout -- to 23 if he came from 55, else to 55, as a
;       jump to the right: dy -8, right held (well_mode 3)
;
; The source clears left/right and never reads the keys while airborne;
; well_mode stops this port's air steering the same way until he lands.
; --------------------------------------------------------------------
well_route
        lda cur_room
        cmpa #39
        bne wr_other
        lda rt_newroom
        cmpa #23
        bne wr_jumpout
        lda upsidedown           ; flipandsettumble
        eora #1
        sta upsidedown
        lda #39
        sta rt_newroom
        lda #180
        sta rt_arrive
        lda #2
        bra wr_mode
wr_jumpout                       ; settojumpout
        ldb #55
        lda well_last
        cmpa #55
        bne wr_jo
        ldb #23
wr_jo
        tfr b,a
        jsr room_exists          ; an unbuilt 23 falls back to 55 rather
        tsta                     ; than pinning him under the top edge
        bne wr_jook
        ldb #55
wr_jook
        stb rt_newroom
        lda #-8
        sta dizzy_dy
        lda #2
        sta dizzy_dir            ; right
        clr dizzy_anim
        lda #3
        sta well_mode
        rts
wr_other
        lda rt_newroom
        cmpa #7
        beq wr_in
        cmpa #39
        bne wr_ret
wr_in                            ; fallenoutof23
        lda cur_room
        sta well_last
        lda #39
        sta rt_newroom
        lda #4
        sta dizzy_dy
        lda #1
wr_mode
        sta well_mode
        clr dizzy_dir
        clr dizzy_anim
wr_ret
        rts

; well_air: once per pass, before gravity. Mode 2 holds dy at -6 (sideback's
; `cp 8 / ld a,-6`; -7 here because the port's gravity then adds 1). Mode 3
; steps right as a held key would, stopped by walls like a real step.
well_air
        lda well_mode
        cmpa #2
        bne wa_not2
        lda #-7
        sta dizzy_dy
        rts
wa_not2
        cmpa #3
        bne wa_ret
        lda dizzy_x
        cmpa #DIZZY_MAXX
        bhs wa_ret
        adda #WALK_STEP
        sta try_x
        ldb #BODY_R               ; T0139: drifting right tests the right edge
        stb cw_side
        jsr check_wall
        bne wa_ret
        lda try_x
        sta dizzy_x
wa_ret
        rts

; well_seq: the sequence the port would pick (3+dir, airborne) becomes 8.
well_seq
        lda well_mode
        cmpa #2
        bne ws_ret
        lda #8
        sta dizzy_seq
ws_ret
        rts

well_mode   fcb 0
well_last   fcb 0

; --------------------------------------------------------------------
; T0125: staging block C -- rooms 39 and 23 -- is the $8000 image's tail,
; but framebuffers A and B (where blocks A/B are staged packed) are full.
; It rides the title's load-time holes instead: tools/mktitle --extra packs
; it after the music, show_title's gather brings it into TITLE_LZ_BUF with
; the rest.
;
; T0146: called ONCE, from boot's show_title (before the transpose
; overwrites the gathered stream), not from new_game any more. RC_DEST
; (rooms 39/23's placement/cmask tables) is read-only for the rest of the
; game -- nothing writes back into staged room data during play, the same
; way framebuffers A/B's staged rooms (52/53 etc.) are only ever unpacked
; once at boot -- so re-unpacking it on every game-over restart was
; unnecessary work that happened to be free while TITLE_LZ_BUF was kept
; resident for show_title_again's sake. Now that game over shows a text
; screen instead (update_death's msg_gameover) and TITLE_LZ_BUF is
; boot-transient, re-unpacking here would read garbage: it must run before
; boot's transpose, not from new_game's game-over path.
; --------------------------------------------------------------------
        if TAPE_ROOMS
        ; T0224: the tape build delivers blocks C and D raw (no unpack_c/_d).
        else
unpack_c
        ldu #TITLE_LZ_BUF+TITLE_LZ_LEN+TITLE_MUSIC_LEN
        ldy #RC_DEST
        jmp lz_unpack
        endif

; --------------------------------------------------------------------
; T0148: unpack_d -- the SAME mechanism as unpack_c above, one stream
; further into the gathered title blob, for the staged CODE block
; (update_dragon + dragon_flames, target/dragon_code.asm) rather than room
; data. Called once from boot's show_title, right after unpack_c and
; strictly before the transpose overwrites TITLE_LZ_BUF -- and strictly
; before new_game/mainloop can ever reach the `jsr update_dragon` this
; makes live. See room36.asm's CODE_DEST for the destination and why it is
; a fixed reservation below BANNER_BUF, not a derived length.
; --------------------------------------------------------------------
        if TAPE_ROOMS
        else
unpack_d
        ldu #TITLE_LZ_BUF+TITLE_LZ_LEN+TITLE_MUSIC_LEN+TITLE_EXTRA_LEN
        ldy #CODE_DEST
        jmp lz_unpack
        endif

; --------------------------------------------------------------------
; T0134: ROOM 84'S DOOR. X-ALL.TXT `doorrou`/`resetdoor` (~3419): the door
; is an ordinary actor (doorhere, frame 177, 8x32 at x=8,y=144), solid like
; any other, so it blocks the bottom-left exit to room 83. While Dizzy stands
; still (sequence 0) in `proxknox` -- raw 34,160,4,16 -> px 8,160,16,16 --
; for the first time, the source runs `chatter knockandentermess`, latched
; by doorhere+oldmovex; here the door's own v1 (actors_init resets it for a
; new game, as the source's resetdoor does).
;
; The door only opens when the brass door knocker (room 89, `proxdoor`) is
; dropped at it, and that room is not in this build: the door stays shut.
; --------------------------------------------------------------------
DOOR_KNOCK_X    equ 8
DOOR_KNOCK_Y    equ 160
DOOR_KNOCK_W    equ 16
DOOR_KNOCK_H    equ 16

; T0162: update_door moved to target/armorog_lifts_dagger_code.asm,
; staged to CODE_DEST (block D) -- it has no call site of its own,
; reached only via update_lifts's own `lbeq update_door` tail-jump,
; so it had to move together with update_lifts. See that file's own
; header for the full reasoning.
