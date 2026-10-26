; T0162: update_rat + rat_newdir + find_loaf_and_eat, update_troll, and
; update_flame_hazard/update_water_hazard/update_fire_hazard (which fall
; through into one shared hazard_scan), CODE ONLY, split out of
; gameplay.asm the same way T0148/T0161 moved update_dragon and
; update_crocodile/update_portcullis -- staged to CODE_DEST (block D,
; included right after croc_portcullis_code.asm inside room36.asm's `org
; CODE_DEST` section) so the RAW bytes they used to cost below $8000 go
; back into the shared title-hole delivery pool (NOTES.md "the port is
; 58 packed bytes short of room 25" / T0159/T0161, same lever, room 22
; this time), at the cost of their (smaller) PACKED size inside block D.
;
; WHY THESE FIVE: each is called from exactly one site in room36.asm's
; mainloop (`jsr update_rat` / `jsr update_troll` / `jsr
; update_flame_hazard` / `jsr update_water_hazard` / `jsr
; update_fire_hazard`), gameplay-only, long after new_game/show_title
; have run -- verified by grep, no other jsr/lbsr/bsr to any of the
; five anywhere in target/. update_flame_hazard/update_water_hazard/
; update_fire_hazard fall through into a shared `hazard_scan` (the
; original file's own factoring, kept: bytes below the framebuffer were
; too tight to duplicate the scan three times even before this move),
; so all four have to move together or not at all.
;
; LOCALS MOVED WITH THE CODE (own `fcb`/`fdb`, exported via
; staged_syms.asm exactly like dragon_code.asm's locals, because
; T0148/T0153's postmortem applies here too): ur_n, fle_n (update_rat/
; find_loaf_and_eat's own scan counters), rat_dir, rat_step,
; rat_target_active, rat_target_x, rat_fled (update_rat's own state --
; nothing outside gameplay.asm reads or writes any of these, confirmed
; by grep before moving), troll_greeted, troll_cooldown (update_troll's
; own state, same check), uf_n/uf_ptr/uf_bw/uf_bh/uf_dy (the hazard
; scan's own working set, likewise exclusive).
;
; gameplay_init (gameplay.asm, resident, runs only from new_game --
; strictly after boot_code.asm's unpack_c/unpack_d have unpacked every
; staged block) still does the same plain absolute writes to rat_dir/
; rat_step/rat_target_active/rat_fled/troll_greeted/troll_cooldown it
; always did -- safe for the same reason it was already safe to `clr
; up_dc` there (T0161). update_item_triggers's uit_loaf branch
; (gameplay.asm, resident -- it is reached through try_pickup, not this
; file's single-hardcoded-call-site rule, so it stayed put) also writes
; rat_target_x/rat_target_active directly, same reasoning.
;
; LEFT RESIDENT, DELIBERATELY NOT MOVED, because something else still
; reads or writes them from outside this file:
;   ratloaf_msg_pending  -- set by find_loaf_and_eat here, but drained
;                            by show_pending_messages (gameplay.asm,
;                            resident, reached from every mainloop pass
;                            via spm_table) -- same shape as
;                            PORT_OPEN_Y/PORT_CLOSED_Y staying with
;                            draw_gate in croc_portcullis_code.asm.
;   rng_ctr               -- fed by room36.asm's rng_step (resident,
;                            called once/pass) and already read from
;                            staged block D by dragon_code.asm's own
;                            dragon_asleep roll, so this is a proven
;                            pattern, not a new one.
;   troll_launching        -- room36.asm's own movement code (ml_landed
;                            and the airborne-suppress checks) both
;                            read AND write it outside this file.
;   troll_bribed           -- set by check_drop_triggers's apple-bribe
;                            branch (gameplay.asm, resident, reached
;                            through try_pickup, not this file's single
;                            call site).
;   killed, cur_room, ah_bx/ah_by/ah_bw/ah_bh -- shared globals, used
;                            everywhere, unmoved from T0148 on.
;
; SAME BUILD RULE AS dragon_code.asm/croc_portcullis_code.asm: `org
; CODE_DEST` directly, NOT a phase block -- lwasm 4.24 miscomputes
; relative branch offsets inside a phase block whenever the physical org
; and the phase target differ, and every routine here has branches. No
; `rmb` at the end: every local is an explicit `fcb`/`fdb`.
;
; Covered by:
;   update_rat       -- harness/actorlife.lua's rat assertion (already
;                        covers the rat's patrol -- see its own table).
;   update_troll     -- harness/actorlife.lua's NEW troll assertion,
;                        added by this task (troll_launching flips 0->1
;                        on contact and the knockback dy actually moves
;                        him -- see that file's own comment for the
;                        break-proof).
;   the hazard trio  -- harness/actorlife.lua's NEW flame-hazard
;                        assertion, added by this task (`killed` flips
;                        when Dizzy stands in room 36's own flame box --
;                        see that file's own comment for the
;                        break-proof). water/fire share hazard_scan with
;                        flame, so the same code path is exercised.
; --------------------------------------------------------------------

; --------------------------------------------------------------------
; update_rat: X-ALL.TXT's `ratrou`/`ratnewdir`/`ratcoll` (~3291), plus
; the T0033 "walk away and vanish" follow-up (find_loaf_and_eat/ur_flee
; below) added from direct playtest feedback -- see gameplay.asm's own
; header comment (still there) for the full writeup this port keeps.
; --------------------------------------------------------------------
update_rat
        ldy #actor_ram
        lda #ACTOR_COUNT
        sta ur_n
ur_loop
        jsr tick_poll             ; T0051 field-boundary sampling
        lda ,y
        cmpa cur_room
        bne ur_next
        lda 1,y
        cmpa #ROU_RAT
        bne ur_next

        ; T0255: X-ALL `delay` of the rat's record is 2 (domoving's delayrou): the routine
        ; runs on every 2nd actor tick, so the rat moves 4 px per 2 ticks (the port ran it every tick = twice as fast).
        lda rat_dly
        eora #1
        sta rat_dly
        lbne ur_done

        tst rat_fled
        bne ur_flee

        dec rat_step             ; T0255: ratrou's `dec oldmovefrm / call z,ratnewdir`: the leg lasts exactly rat_step RUNS
        bne ur_boundcheck
        jsr rat_newdir
ur_boundcheck
        lda 2,y                  ; current x
        ldb rat_dir
        bne ur_boundright
        cmpa #RAT_MIN_X
        bhi ur_move
        jsr rat_newdir
        bra ur_move
ur_boundright
        cmpa #RAT_MAX_X
        blo ur_move
        jsr rat_newdir
ur_move
        lda rat_dir
        sta 5,y                   ; v1: facing
        lda 2,y                  ; x
        ldb rat_dir
        beq ur_left
        adda #RAT_STEP_SIZE
        bra ur_store
ur_left
        suba #RAT_STEP_SIZE
ur_store
        sta 2,y

        jsr actor_hit
        tsta
        beq ur_nohit
        lda #1
        ldx #msg_ratgotyou       ; T0216b
        jsr kill_dizzy_msg
ur_nohit
        tst rat_target_active
        beq ur_done
        lda 2,y                  ; rat's just-updated x
        suba rat_target_x
        bpl ur_tgabs
        nega
ur_tgabs
        cmpa #RAT_STEP_SIZE
        bhs ur_done
        clr rat_target_active
        jsr find_loaf_and_eat
        lda #1
        sta rat_fled
        bra ur_done
ur_next
        leay ACTOR_STRIDE,y
        dec ur_n
        lbne ur_loop            ; T0216b: ldx #msg_ratgotyou pushed this past -128
ur_done
        rts

ur_flee
        lda 5,y
        bne ur_flee_move
        lda #1
        sta 5,y
ur_flee_move
        lda 2,y
        cmpa #RAT_FLED_X
        bhs ur_flee_gone
        adda #RAT_STEP_SIZE
        cmpa #RAT_FLED_X
        bls ur_flee_store
        lda #RAT_FLED_X
ur_flee_store
        sta 2,y
        bra ur_flee_hit
ur_flee_gone
        lda #255
        sta ,y
        sta bufA_last_x
        sta bufB_last_x
        bra ur_done
ur_flee_hit
        jsr actor_hit
        tsta
        beq ur_done
        lda #1
        ldx #msg_ratgotyou       ; T0216b
        jsr kill_dizzy_msg
        bra ur_done

; rat_newdir: picks a new random countdown (16-31) and flips rat_dir --
; see gameplay.asm's own header comment for the RNG derivation writeup.
rat_newdir
        lda rng_ctr
        anda #15
        adda #16
        sta rat_step
        lda rat_dir
        eora #1
        sta rat_dir
        rts

; find_loaf_and_eat: the rat reached its target -- remove the loaf actor
; (room=255). Scans by frame id, same reasoning as update_rat's own
; search. Uses X; Y (the rat's own record, still needed by the caller
; after this returns) is untouched.
find_loaf_and_eat
        ldx #actor_ram
        lda #ACTOR_COUNT
        sta fle_n
fle_loop
        lda ,x
        cmpa cur_room
        bne fle_next
        lda 4,x
        cmpa #FRAME_LOAF
        bne fle_next
        lda #255
        sta ,x
        bra fle_done
fle_next
        leax ACTOR_STRIDE,x
        dec fle_n
        bne fle_loop
fle_done
        lda #1
        sta ratloaf_msg_pending
        rts

; --------------------------------------------------------------------
; update_troll: real physics knockback -- see gameplay.asm's own header
; comment (still there) for the full writeup: why a real jump/gravity
; launch rather than a scripted animation, why dizzy_dir is forced to 1
; at launch, and why the message is shown BEFORE the launch and dropped
; entirely on later encounters' resend path.
; --------------------------------------------------------------------
        if TAPE_ROOMS
; T0239: update_troll is table-driven in the tape build -- X-ALL.TXT's
; minerrou (room 41, ~3466) "reuses trollrou's shove-back": proxminerou
; hides the troll (trollhere+room=255), calls proxtrollrou (the SAME
; shove: x-=2, dy=-9, sequence 4, facing left) and, the FIRST time
; only (miner var1==0), shows goawaymess instead of getbackintheremess.
; So the launch below is shared; only the box, the gating and the
; message differ per room. ut_tab: room, box x,y,w,h (pixels; x=(raw-32)*4,
; w=raw*4: proxminer raw (90,120,2,32) -> (232,120,8,32)).
update_troll
        lda troll_cooldown
        beq ut_nocooldown
        deca
        sta troll_cooldown
ut_nocooldown
        tst troll_launching
        lbne ut_done
        lda troll_cooldown
        lbne ut_done
        ldx #ut_tab
ut_find
        lda ,x
        lbeq ut_done
        cmpa cur_room
        beq ut_have
        leax 5,x
        bra ut_find
ut_have
        cmpa #36
        bne ut_nobribe
        lda troll_bribed
        lbne ut_done
ut_nobribe
        lda 1,x
        sta ah_bx
        lda 2,x
        sta ah_by
        lda 3,x
        sta ah_bw
        lda 4,x
        jsr aabb_test
        lbeq ut_done
        lda cur_room
        cmpa #36
        bne ut_miner
        tst troll_greeted
        bne ut_showmsg
        inc troll_greeted
        bra ut_launch
ut_miner
        lda #ROU_MINER
        ldy #actor_init_tape
        ldb #ACTOR_COUNT_tape
        bsr ut_findrou
        cmpy #0
        beq ut_launch
        lda #41
        sta ,y                   ; the miner steps into view...
        lda #232
        sta 2,y                  ; ...at movex=90 raw
        lda 5,y
        bne ut_hidetroll         ; var1 already 1: no message
        lda #1
        sta 5,y
        ldx #msg_goaway
        bra ut_msgthen
ut_hidetroll
        lda #ROU_TROLL
        ldy #actor_ram
        ldb #ACTOR_COUNT
        bsr ut_findrou
        cmpy #0
        beq ut_bribe
        lda #255
        sta ,y                   ; trollhere+room = 255
ut_bribe
        lda #1
        sta troll_bribed
        bra ut_launch
ut_showmsg
        ldx #msg_troll
ut_msgthen
        jsr msg_begin
        jsr prtmessage
        jsr msg_wait_dismiss
        jsr box_reset            ; T0258 (D1): windowrou1
        lda cur_room
        cmpa #36
        beq ut_launch
        bra ut_hidetroll
ut_launch
        lda #1
        sta troll_launching
        lda #TROLL_COOLDOWN
        sta troll_cooldown
        lda #1
        sta dizzy_dir
        lda #TROLL_LAUNCH_DY
        sta dizzy_dy
        clr dizzy_floor
        jsr force_redraw
ut_done
        rts
; ut_findrou: A=routine id, Y=table, B=count -> Y=first record with that
; routine, or Y=0.
ut_findrou
        cmpa 1,y
        beq utf_ret
        leay ACTOR_STRIDE,y
        decb
        bne ut_findrou
        ldy #0
utf_ret
        rts
ut_tab
        fcb 36,TROLL_BOX_X,TROLL_BOX_Y,TROLL_BOX_W,TROLL_BOX_H
        fcb 41,232,120,8,32
        fcb 0
        else
update_troll
        lda troll_cooldown
        beq ut_nocooldown
        deca
        sta troll_cooldown
ut_nocooldown
        tst troll_launching
        bne ut_done
        lda cur_room
        cmpa #36
        bne ut_done
        lda troll_bribed
        bne ut_done
        lda troll_cooldown
        bne ut_done

        lda #TROLL_BOX_X
        sta ah_bx
        lda #TROLL_BOX_Y
        sta ah_by
        lda #TROLL_BOX_W
        sta ah_bw
        lda #TROLL_BOX_H
        jsr aabb_test          ; T0221 (was 7 bytes inline)
        beq ut_done

        tst troll_greeted
        bne ut_showmsg
        inc troll_greeted
        bra ut_nomsg
ut_showmsg
        jsr msg_begin
        ldx #msg_troll
        jsr prtmessage
        jsr msg_wait_dismiss
        jsr box_reset            ; T0258 (D1): windowrou1
ut_nomsg

        lda #1
        sta troll_launching
        lda #TROLL_COOLDOWN
        sta troll_cooldown
        lda #1
        sta dizzy_dir
        lda #TROLL_LAUNCH_DY
        sta dizzy_dy
        clr dizzy_floor
        jsr force_redraw       ; T0221 (was 8 bytes inline)
ut_done
        rts
        endif

; --------------------------------------------------------------------
; update_flame_hazard/update_water_hazard/update_fire_hazard: see
; gameplay.asm's own header comment (still there) for the full T0026/
; T0032/T0138 writeup -- the sprite-size corrections in particular.
; hazard_scan is shared: bytes below the framebuffer were too tight to
; duplicate this loop three times even before this move.
; --------------------------------------------------------------------
update_flame_hazard
        ; T0216: the three entries share hazard_scan, so each latches its own
        ; death line for the shared tail to hand to kill_dizzy_msg. The
        ; original does the same by loading HL before calling killdizzy1.
        ldd #msg_killedbyflame
        std haz_msg
        lda room_flame_count
        lbeq uf_done
        sta uf_n
        ldx room_flames_ptr
        stx uf_ptr
        lda #16
        sta uf_bw
        lda #13
        sta uf_bh
        clr uf_dy
        bra hazard_scan
update_water_hazard
        ; T0216b: X-ALL.TXT's updatewaterlp picks the line by ROOM --
        ; `ld a,(roomno) / cp 77 / jr z,yesfellinlava` -- so room 77's water
        ; is the volcano's lava and reads differently from every other pool.
        ; A is loaded FIRST: `ldd #msg` then `lda cur_room` would clobber D's
        ; high byte.
        lda cur_room
        cmpa #77
        beq uw_lava
        ldd #msg_killedbywater
        bra uw_havemsg
uw_lava
        ldd #msg_killedbyvolcano
uw_havemsg
        std haz_msg
        lda room_water_count
        beq uf_done
        sta uf_n
        ldx room_water_ptr
        stx uf_ptr
        lda #6
        sta uf_dy
        lda #32
        sta uf_bw
        lda #6
        sta uf_bh
        bra hazard_scan
update_fire_hazard
        ldd #msg_killedbyflame   ; T0216: room 36's fire pit burns you too
        std haz_msg
        lda cur_room
        cmpa #36
        bne uf_done
        tst fireout
        bne uf_done
        lda r2_room_flame_count
        beq uf_done
        sta uf_n
        ldx #r2_room_flames
        stx uf_ptr
        lda #16
        sta uf_bw
        lda #13
        sta uf_bh
        clr uf_dy
hazard_scan
uf_loop
        jsr tick_poll             ; T0051 field-boundary sampling
        ldx uf_ptr
        lda ,x+
        sta ah_bx
        lda ,x+
        adda uf_dy
        sta ah_by
        stx uf_ptr
        lda uf_bw
        sta ah_bw
        lda uf_bh
        jsr aabb_test          ; T0221 (was 7 bytes inline)
        beq uf_next
        lda #1
        ldx haz_msg              ; T0216 (uf_loop reloads X from uf_ptr every
        jsr kill_dizzy_msg         ; iteration, so clobbering it here is safe)
uf_next
        dec uf_n
        bne uf_loop
uf_done
        rts

ur_n                fcb 0
fle_n               fcb 0
rat_dir             fcb 0
rat_step            fcb 60
rat_dly             fcb 0     ; T0255: delay-2 phase: toggled each call, the call that leaves it 0 runs
rat_target_active   fcb 0
rat_target_x        fcb 0
rat_fled            fcb 0
troll_greeted       fcb 0
troll_cooldown      fcb 0
uf_n                fcb 0
uf_ptr              fdb 0
uf_bw               fcb 0
uf_bh               fcb 0
uf_dy               fcb 0

; T0216b: these three streams live HERE, inside staged block D, not in
; gap_messages.asm -- the resident low region ($0100-$0DFF) is full and
; adding them there overflowed it into start: at $0E00. They are referenced
; ONLY by update_water_hazard and update_rat in this same file, so unlike
; gap_messages' streams they need no entry in stage_pack.sh's export list.
; X-ALL.TXT's killedbywater (1022), killedbyvolcano (1040) and
; ratgotyoumess (1035), byte-for-byte. All three print INSIDE deadwindow's
; box, so none carries a drawbox of its own.
msg_killedbywater
        fcb 128+17,88
        fcc "@orig(X-ALL:1023/15)"
        fcb 128+15,100
        fcc "@orig(X-ALL:1024/17)"
        fcb 0
msg_killedbyvolcano
        fcb 128+18,88
        fcc "@orig(X-ALL:1019/14)"
        fcb 128+17,96
        fcc "@orig(X-ALL:1042/15)"
        fcb 128+18,104
        fcc "@orig(X-ALL:1043/14)"
        fcb 0
msg_ratgotyou
        fcb 128+20,88
        fcc "@orig(X-ALL:1036/12)"
        fcb 128+20,96
        fcc "@orig(X-ALL:1037/12)"
        fcb 128+23,104
        fcc "@orig(X-ALL:1038/9)"
        fcb 0


haz_msg             fdb 0     ; T0216: which death line this hazard type uses
