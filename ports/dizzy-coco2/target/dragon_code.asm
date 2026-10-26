; T0148: update_dragon + dragon_flames, CODE ONLY, split out of gameplay.asm
; and staged to CODE_DEST ($8000+, immediately below BANNER_BUF) -- the
; proof-of-concept that RESIDENT CODE, not just room data, can be staged
; and unpacked at boot exactly the way room data already is (NOTES.md
; "Why a 64K machine is tighter" -- the relief valve nobody had tried).
;
; WHY THIS ROUTINE: it is room 54's dragon update, called from exactly one
; site (room36.asm mainloop's `jsr update_dragon`, gameplay-only, long
; after new_game/show_title have run) and self-contained -- every local it
; touches (dgf_i, dgf_x, udr_n, udr_slot, udr_head_y, dragon_swing,
; dragon_delay, dragon_asleep, dragon_fire, dragon_headfrm, dragon_flame_n,
; dragon_flame_x) is a plain fcb/fdb, left resident in gameplay.asm at its
; ORIGINAL low address -- only the CODE moves, per T0148's brief. draw_dragon
; (room36.asm) and dragon_necky (room36.asm) read those same variables and
; are UNCHANGED: absolute addressing does not care where the code reading
; them lives, only where the variables themselves are, and those did not
; move.
;
; DELIVERY: packed as its own LZSS stream riding the title's load-time
; holes, the same mechanism as block C (rooms 39/23, T0125) but as a
; SEPARATE stream (mktitle's new --extra2), not appended to block C's --
; concatenating would force it to decode contiguously with block C's
; destination, colliding with the "top of the room-growth span, below
; BANNER_BUF" placement this task calls for. See room36.asm's CODE_DEST
; and tools/roompack/src/bin/mktitle.rs.
;
; Unpacked once at boot, by logic_low.asm's unpack_d, called from
; boot_code.asm's show_title right after unpack_c and before the title
; transpose -- i.e. strictly before new_game, strictly before mainloop can
; ever call update_dragon.
;
; WALL HIT, then a REAL fix (not a workaround): lwasm 4.24 (`lwasm
; --version`) computes relative-branch offsets INSIDE a `phase` block using
; the PHYSICAL (org) address of one operand and the LOGICAL (phase)
; address of the other -- confirmed with a 2-instruction repro (`beq` two
; bytes from its target, `org $1000 / phase $9000`: the assembled offset
; came out as (true_offset - (phase-org)), i.e. off by exactly the
; org/phase gap, not by a rounding slip). Short branches usually then trip
; lwasm's own overflow check and fail loud; LONG branches (lbeq etc) have
; enough range to silently accept the WRONG offset and assemble clean --
; tried first, looked like a fix because the build succeeded, but the
; emulator proved it wasn't: `update_dragon` branched into unmapped memory
; every time cur_room=54, and breathsfx.lua's harness (harness/breathsfx.lua)
; caught it stone cold -- dragon_swing/dragon_fire/rng_ctr never moved for
; 300 frames where the unstaged original took under 500. rate.lua and the
; other harnesses in T0148's verify list did NOT catch it (a wrong branch
; into RAM that happens to be zero-filled just executes NEG opcodes
; harmlessly until an RTS turns up by chance -- no crash, no hang, just the
; routine quietly doing nothing). Moral: a routine with no branches at all
; (every room-data block before this one) can't expose this bug; a harness
; that pokes the routine's OWN state, not just "did the game keep running",
; is what caught it.
;
; THE FIX: this file is not assembled inside `phase` at all any more --
; room36.asm orgs straight to CODE_DEST (see its own comment). Pass 1 is
; the raw/STAGE_GEN measurement pass and is never loaded on real hardware
; (same as block C above it), so assembling directly at the real $8000+
; address costs nothing and every branch offset is then correct by
; construction, exactly as the org==phase control case of the same repro
; confirmed. Branches here are back to their natural short forms.
update_dragon
        lda cur_room
        cmpa #54
        beq udr_inroom
        rts
udr_inroom
        ; already fully retracted and asleep: the source's own `ret z`
        ; -- nothing more ever changes, so touch nothing.
        lda dragon_asleep
        beq udr_awake
        lda dragon_swing
        cmpa #-8
        bne udr_awake
        rts
udr_awake
        ldx #actor_ram
        lda #ACTOR_COUNT
        sta udr_n
udr_find
        lda ,x
        cmpa cur_room
        bne udr_findnext
        lda 1,x
        cmpa #ROU_DRAGON
        beq udr_found
udr_findnext
        leax ACTOR_STRIDE,x
        dec udr_n
        bne udr_find
        rts
udr_found
        ; T0255: X-ALL dragonrou -> trytostartbreathing runs BEFORE the swing and the head are drawn, and when it
        ; starts a breath it `pop hl / jp alreadybreathing`: that very tick keeps the swing, draws the head with the
        ; breath frame (110) and runs the first flame step.  The roll used to follow the head, one tick late.
        tst dragon_asleep
        bne udr_headgo            ; a sleeping dragon never breathes fire
        tst dragon_fire
        bne udr_headgo
        ; not currently breathing: the source's own random 5/256 per-
        ; tick chance (`justrandomfire` -- this build has no golden-egg
        ; state to special-case, so that's the only path that applies).
        ; Reuses the free-running LFSR (rng_step, room36.asm) rather
        ; than a second generator -- it is already sampled by unrelated
        ; subsystems every pass, which is exactly what makes it a valid
        ; source of "unpredictable" bits for this one too.
        lda rng_ctr
        cmpa #5
        bhs udr_headgo
        lda #1
        sta dragon_fire
        jsr play_breath          ; T0111: sndfx 10, X-ALL.TXT startbreath
udr_headgo
        jsr dragon_head

        ; asleep and only just now reached -8: this is the LAST active
        ; tick (matches the source drawing once more before the next
        ; call's `ret z`) -- fall through and draw/collide-check the
        ; flame state normally; draw_dragon will stop after this pass.

        tst dragon_asleep
        bne udr_nofire
        tst dragon_fire
        beq udr_nofire
        jsr dragon_flames         ; positions + collision + the wrap/inc
udr_nofire
        rts

; dragon_head: X = the dragon's actor slot (actor_ram for room 54, actor_init_tape for room 40).
; Advances the swing (asleep: retract toward -8; awake: the triangle wave, frozen mid-breath),
; picks the head frame, writes the head's CURRENT state into the slot and kills Dizzy on a head
; hit. Shared by update_dragon and tape_code.asm's update_dragon40 (T0254: they were two copies).
; Clobbers A, B, X, Y; sets udr_slot and udr_head_y.
dragon_head
        stx udr_slot

        ; T0133: proxsleep used to fire here on mere proximity (any
        ; visit to the box). The source only fires it via `justexitinvent`
        ; -> checkproximity when the [X-ALL.TXT line 642] is dropped in the
        ; box -- see check_drop_trigger's cdt_potion branch, which is now
        ; the only place dragon_asleep gets latched (plus the debug key,
        ; DBG_DRAGON_KEY below).

        lda dragon_asleep
        beq udr_swingawake
        ; asleep, still retracting: decrement toward -8, no swing-wave,
        ; no fire (a sleeping dragon does not breathe).
        lda dragon_swing
        deca
        cmpa #-8
        bge udr_haveswing         ; SIGNED compare -- floor at -8. (An
                                    ; unsigned bhs/blo here would be wrong:
                                    ; swing spans both small positive
                                    ; values (0..16) and small negative
                                    ; ones (-8..-1), which as unsigned
                                    ; bytes are 0..16 vs 248..255 -- the
                                    ; two ranges sort backwards from
                                    ; their signed order.)
        lda #-8
        bra udr_haveswing
udr_swingawake
        ; breathing freezes the swing exactly where it was (the
        ; source's own `alreadybreathing` skip) -- only advance the
        ; triangle wave when NOT currently mid-breath.
        lda dragon_fire
        bne udr_haveswing_cur
        lda dragon_delay
        inca
        anda #31
        sta dragon_delay
        cmpa #16
        blo udr_swinglo
        nega
        adda #32
        bra udr_haveswing
udr_swinglo
udr_haveswing
        sta dragon_swing
        bra udr_swingdone
udr_haveswing_cur
        lda dragon_swing
udr_swingdone

        ; head position + frame, from the (possibly just-updated) swing
        lda #DRAGON_ORIGY
        suba dragon_swing
        sta udr_head_y
        lda #109                  ; idle / second half of a breath
        ldb dragon_fire
        beq udr_headframeok       ; not breathing at all: 109
        decb
        cmpb #16
        bhs udr_headframeok       ; second half of the cycle: still 109
        lda #110                  ; first half: mid-roar
udr_headframeok
        sta dragon_headfrm

        ; write the head's CURRENT animated state into the slot so
        ; actor_hit (which reads frame/x/y straight from it) tests
        ; against where the head actually is this tick, not its rest
        ; position.
        ldx udr_slot
        lda dragon_headfrm
        sta 4,x
        lda #DRAGON_HEAD_X
        sta 2,x
        lda udr_head_y
        sta 3,x
        ldy udr_slot
        jsr actor_hit
        tsta
        beq udr_nothead
        ldx #msg_dragon
        jsr kill_dizzy_msg
udr_nothead
        rts

; dragon_flames: dragon_fire is nonzero. Computes this tick's visible
; flame positions (X-ALL.TXT's `printdragonflame`, simulated in Python
; before writing this to confirm the six-iteration form is exact),
; tests each against Dizzy, and advances the cycle.
dragon_flames
        clr dragon_flame_n
        lda #6
        sta dgf_i
dgf_loop
        lda dgf_i
        asla                     ; A = dgf_i*2
        adda #68                 ; A = dgf_i*2 + 68
        suba dragon_fire         ; A = pos = dgf_i*2 - dragon_fire + 68
        cmpa #50
        blo dgf_next               ; pos < 50: not yet visible
        cmpa #68
        bhs dgf_next               ; pos >= 68: already past the mouth

        ; visible: pixel_x = (pos-32)*4, record it and test the hit
        suba #32
        lsla
        lsla
        sta dgf_x
        sta ah_bx
        lda udr_head_y
        adda #8
        sta ah_by
        lda aspr_112_w
        sta ah_bw
        lda aspr_112_h
        jsr aabb_test          ; T0221 (was 7 bytes inline)
        beq dgf_nothit
        ldx #msg_dragonfire
        jsr kill_dizzy_msg
dgf_nothit
        ldb dragon_flame_n
        ldx #dragon_flame_x
        abx
        lda dgf_x
        sta ,x
        inc dragon_flame_n
dgf_next
        dec dgf_i
        bne dgf_loop

        lda dragon_fire
        inca
        cmpa #48
        blo dgf_storefire
        clra
dgf_storefire
        sta dragon_fire
        rts

; T0148: the local variables, moved here WITH the code (see gameplay.asm's
; own note at the old site for why they could not stay resident below
; $8000 -- pass 1/pass 2 disagree on low-memory addresses by exactly the
; size gap between STAGE_LZ's two boot mechanisms, and these are the first
; staged bytes that ever referenced a low address). draw_dragon and
; dragon_necky (room36.asm, unmoved) still reach dragon_swing/dragon_
; asleep/dragon_headfrm/dragon_fire/dragon_flame_n/dragon_flame_x/
; udr_head_y by plain absolute addressing -- staged_syms.asm exports their
; CODE_DEST-relative addresses explicitly for pass 2 (tools/stage_pack.sh),
; the same way it exports update_dragon itself.
dgf_i        fcb 0
dgf_x        fcb 0

udr_n       fcb 0
udr_slot    fdb 0
udr_head_y  fcb 0

dragon_swing    fcb 0    ; signed: 0..16 awake, decrementing to -8 asleep
dragon_delay    fcb 0    ; 0..31, drives the triangle wave
dragon_asleep   fcb 0    ; latched permanently by the proxsleep trigger
dragon_fire     fcb 0    ; 0 = not breathing; 1..47 = a breath cycle
dragon_headfrm  fcb 109  ; 109 or 110, precomputed for draw_dragon
; T0148: dragon_flame_x (rmb, no emitted bytes) moved BEFORE dragon_flame_n
; rather than after it -- lwasm does not emit trailing bytes for an `rmb`
; that ends a block with nothing after it, so the DECB block stage_pack.sh
; extracts came out 6 bytes short of code_staged_end-code_staged_start
; (caught by whole_block's own length check, not guessed). Ending on a
; real `fcb` keeps the block's actual emitted length matching the map.
dragon_flame_x  fcb 0,0,0,0,0,0   ; T0148: explicit zeros, not rmb -- lwasm emits
                 ; nothing for an rmb, and stage_pack's length guard
                 ; compares emitted bytes against the map    ; their pixel x, precomputed by dragon_flames
dragon_flame_n  fcb 0    ; how many of dragon_flame_x are valid this tick
