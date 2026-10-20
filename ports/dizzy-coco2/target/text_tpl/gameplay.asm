; --------------------------------------------------------------------
; T0029/T0030/T0031/T0032: the dungeon-escape puzzle -- hazards, death,
; the rat and troll behaviours, and the proximity puzzles that connect
; them. Grouped in one file because they are genuinely one system: the
; troll blocks the exit until bribed with the apple, the jug puts out
; the fire to escape, and both the rat and the flame kill Dizzy the
; same way. Splitting them into four separate files would have meant
; three of them half-referencing state the fourth one owns.
;
; SCOPE, stated up front: this covers rooms 35/36 only, matching the
; vertical slice this port has actually built (NOTES.md "Prototype
; scope").
;
; T0033: the loaf->rat distraction mechanic (deferred above, now built).
; X-ALL.TXT's version (`proxloafrou`/`ratcoll`, ~3322-3349): dropping the
; loaf inside `proxloaf`'s box self-modifies a literal byte inside the
; rat's own routine to the loaf's exact raw x+2; every `ratrou` tick
; thereafter compares the rat's raw x against that literal with `cp`,
; an EXACT match. That can't port as-is: the original moves the rat and
; Dizzy 1 raw px/tick, so an exact x match is always reachable, but this
; port moves both in RAT_STEP_SIZE/WALK_STEP=4px strides on a coordinate
; grid where the rat's x is always a multiple of 4 (RAT_MIN_X=48,
; RAT_STEP_SIZE=4) while a dropped item's x is `dizzy_x+4` and dizzy_x
; is never a multiple of 4 (spawns at 46) -- so an exact-match test can
; provably never fire, ever, the same class of bug as the apple/jug
; boxes being narrower than one walk stride (T0032's own note). Reached
; with a tolerance instead: within RAT_STEP_SIZE of the target counts as
; "there", which -- because the rat's distance to the target changes by
; exactly RAT_STEP_SIZE per tick -- is guaranteed to fire exactly once
; per pass through the target, never skippable, without needing the
; grids to align. See rat_target_x/check_rat_target below.
; --------------------------------------------------------------------

KILL_COUNTDOWN  equ 10      ; matches the original's killdizzy (ld a,10)
; The troll's launch is its own velocity, one more than a player jump:
; proxtrollrou does `ld a,-9 / ld (dy),a` (X-ALL.TXT ~3359). This port had
; been reusing JUMP_DY (-8) for it. The original ALSO shoves Dizzy 2 units
; (8px) west at the same moment -- that half is deliberately not copied,
; because this port already applies a CONTINUOUS horizontal push for the
; duration of the flight instead (see room36.asm's own note on why the
; source's one-time nudge barely read as a knockback here).
TROLL_LAUNCH_DY equ -9
; Real mechanic, found by finally reading `ratnewdir`/`random`
; (X-ALL.TXT ~3334/~5128) instead of guessing a fixed amplitude a
; fourth time: the original doesn't patrol a fixed distance at all --
; each leg's DURATION is random (`call random / and 15 / add a,16`,
; giving 16-31 mainloop ticks before the next direction flip), so the
; excursion length varies leg to leg. Reproduced exactly (same 16-31
; range, same AND-15-then-ADD-16 shape) via `rat_newdir` below.
;
; RAT_STEP_SIZE: pixels moved per tick while patrolling. The original
; moves 1px/tick (same real step this port found for Dizzy's own
; walk -- see WALK_STEP's own comment in room36.asm). Reported back as
; "super slow" for the same reason Dizzy's did, and fixed the same way:
; matched to WALK_STEP rather than to the source, for a snappier feel
; over strict fidelity.
RAT_STEP_SIZE   equ WALK_STEP
;
; CORRECTION: earlier versions of this comment claimed "the original
; doesn't [bound the rat by position] explicitly (it's bounded purely
; by time, not position)". That was wrong, found by finally reading
; `ratrou` itself (X-ALL.TXT ~3291) instead of inferring from
; `ratnewdir` alone. The original DOES have a hard position bound: it
; compares the rat's x against two literal values living in ITS OWN
; movingdata record (repurposed `oldmovex`/`oldmovey` fields, NOT real
; old-position tracking -- same "same bytes, different meaning per
; routine" pattern already documented for `pickupable` elsewhere in
; this file) and forces a new random direction on an exact match. For
; room 36's rat those raw values are 44 and 80.
;
; Those are RAW values, in the same coordinate space as the rat's own
; raw spawn x (42) -- and this port already separately proved (see
; NOTES.md "Real bug found via user playtest: movingdata actor x
; needed the SAME room-placement transform") that any x flowing
; through the original's shared `frame` blit routine needs `(x-32)*4`
; to land correctly in this port's real-pixel space; that exact fix is
; what corrected the troll's box position. The rat's own spawn IS that
; transform already applied ((42-32)*4=40, matching actor_data.asm's
; committed x exactly) -- oldmovex/oldmovey go through the identical
; path and had simply never been carried over before now:
;   RAT_MIN_X = (44-32)*4 = 48
;   RAT_MAX_X = (80-32)*4 = 192
; A ~144px range, not the ~48-84px this port had been guessing at
; across two earlier (heuristic, collision-mask-based) attempts -- real
; playtest after the second of those: "still limited movements and
; it's always the same length". Verifying this against the running
; original directly (as asked) hit a real MAME/Lua tooling wall this
; session couldn't get past (`manager.machine:load()` silently breaks
; all further periodic callbacks for the rest of the session -- a
; genuine, previously-undiscovered harness limitation, not something
; to retry the same way), so this is confirmed by re-deriving the exact
; mechanic and reusing an already-validated transform, not by eyeballing
; the real game -- flagging that distinction rather than overstating
; the confidence level.
RAT_MIN_X    equ 48
RAT_MAX_X    equ 192
; RAT_FLED_X: where the fed rat walks to before vanishing (T0033
; follow-up, ur_flee below) -- the real exit is a hole in the wall at
; x=248/252 (the only fully-open columns anywhere in the room's
; compiled cmask), but the rat's own sprite is 32px wide and `blit`
; doesn't clamp at the screen edge, so 224 (224+32=256 exactly) is the
; furthest right it can walk with its full sprite still on screen.
RAT_FLED_X   equ 224
; T0050: death respawn is a per-room CHECKPOINT in the original, not a
; fixed point. `enterroom` (X-ALL.TXT ~6787) runs on every single room
; change and does exactly this:
;     ld a,(newroomno) / ld (roomno),a / ld (startroom),a
;     ld a,(x) / ld (startx),a
;     ld a,(y) / ld (starty),a
; and `starteggres` (~6751) copies startroom/startx/starty back into
; roomno/x/y when a life is lost. So you always restart wherever you
; walked into the room you died in. `resetlives` only seeds those three
; for the very first life of a new game (room 36 at 46,168 -- see
; start:'s own comment on the unit conversion).
;
; This port had them as fixed constants, which is why every death dumped
; you back in the dungeon no matter where you had got to -- and, once
; rooms 52/53 existed, made dying anywhere up there a much bigger setback
; than the original ever intended. `set_checkpoint` below is enterroom.
respawn_room    fcb 36
respawn_x       fcb 184
respawn_y       fcb 168

; set_checkpoint: enterroom's own three stores. Called from every room
; transition AND from the initial spawn, always AFTER cur_room/dizzy_x/
; dizzy_y have been set to the arrival position.
set_checkpoint
        lda cur_room
        sta respawn_room
        lda dizzy_x
        sta respawn_x
        lda dizzy_y
        sta respawn_y
        rts

; Proximity boxes, recovered by tools/actordata (T0024) from the
; original's own proxapple/proxjug/proxtroll definitions.
;
; T0053 -- BOTH x AND w need the transform, and only x ever got it. The
; original compares a box against Dizzy in the box's own coordinate
; space: `joinprox` (X-ALL.TXT ~1991) does `ld a,(x) / add a,32` to move
; DIZZY into that space, and the very next lines use `eggwidth equ 6`
; as his width there -- 6 units for a sprite that is 24 pixels wide, so
; one unit is 4 pixels and a box's WIDTH is in those same units. `h` is
; NOT scaled: the vertical half of the same routine uses `eggheight equ
; 18`, plain pixels, matching y.
;
; So every box in this port has been a QUARTER of its real width since
; T0024. The loaf's is the one that bites: 40px instead of 160px, i.e.
; only ~10 of the ~40 stride-aligned positions along the rat's corridor
; actually armed it -- which reads in play as "the rat won't eat the
; bread", seemingly at random or tied to whatever else you happened to
; do first. Reported twice; the first investigation wrongly cleared it
; because the scripted test happened to drop from inside the narrow band.
;
; It also explains T0032's own note below about the apple and jug boxes
; being "unreachably narrow" and needing hand-widening: they were never
; 4px and 6px wide, they were 16px and 24px. The hand-tuned numbers are
; reverted here to the source's own, now that the transform is right.
; X values are PIXEL_X -- (raw_x - 32) * 4 -- not the raw on-disk x. Real playtest
; found the troll (and everything else placed via movingdata) rendering
; suspiciously bunched in the room's left third, the exact signature of
; the room-placement transform bug found earlier this port (NOTES.md
; "Correction #2") -- turned out to apply here too: traced the
; original's shared `frame` blit routine and `proximitycollide`
; directly (X-ALL.TXT ~4136 and ~1923) and both apply the identical
; `sub 32`/`srl a` to x. Y is NOT rescaled (used directly as a screen
; row, same as room placements).
TROLL_BOX_X     equ 200
TROLL_BOX_Y     equ 136
TROLL_BOX_W     equ 32
TROLL_BOX_H     equ 32
; Grace period (mainloop passes) after landing before he can be
; re-triggered. X-ALL.TXT's own proxtrollrou has an equivalent guard
; (checks the current sprite frame and skips re-firing while still mid-
; tumble) -- this port never carried an equivalent over, so a player who
; keeps holding the approach key after landing (natural: that's the same
; key that walked them in) walks straight back into the box and gets
; re-launched before they can react. Real playtest: "message shows up
; but disappears straight away, then I have to click a key to resume"
; -- that's this exact rapid re-trigger, not a dismiss-logic bug (a
; clean automated test holding one key with nothing else pressed proved
; the dismiss wait itself never falsely fires). ~30 passes is a bit
; under 2 seconds at this port's ~17Hz pace -- enough to read the
; message and back off, matched to feel rather than to any original
; source timing (the original's own guard is frame-based, not time-
; based, and doesn't translate directly).
;
; Counts down from the moment of LAUNCH, not landing (simpler than
; hooking room36.asm's ml_landed, which is generic to every jump/fall,
; not just this one) -- the tumble itself burns ~17 passes end to end
; (measured), so this is sized at ~17 + a real ~30-pass grace period
; once he's actually back in control.
TROLL_COOLDOWN  equ 47
; Widened from the source's own raw values (transformed: apple 4px,
; jug 6px) -- those match the ORIGINAL's 1px/tick movement fine (many
; valid stopping pixels), but this port deliberately walks in
; WALK_STEP=4px strides (see its own comment on why -- source fidelity
; there felt worse, not better). A box narrower than the stride has AT
; MOST ONE reachable stopping position in the whole walkable range,
; with zero visual indication of where it is -- confirmed by computing
; it directly: apple had exactly one valid dizzy_x (182), jug exactly
; one (46, spawn itself). Real playtest: "no event is firing", which
; was never a usage mistake -- the box was there, just practically
; unreachable by feel. Widened generously (apple stays clear of the
; troll's own box at x=200; jug stays clear of the left wall at ~x=38)
; so several stride-aligned positions land inside each, same spirit as
; REACH_MARGIN's earlier fix to pickup reach.
APPLE_BOX_X     equ 184
APPLE_BOX_Y     equ 152
APPLE_BOX_W     equ 16
APPLE_BOX_H     equ 16
JUG_BOX_X       equ 48
JUG_BOX_Y       equ 150
JUG_BOX_W       equ 24
JUG_BOX_H       equ 26

; proxloaf (X-ALL.TXT ~3341): raw x=46,y=64,w=40,h=16. X transformed
; (46-32)*4=56, same formula as the apple/jug/troll boxes above; y/w/h
; carry across unchanged (already established: only the X POSITION gets
; the *4, box extents don't -- confirmed by TROLL_BOX_W/_H matching
; their raw values exactly). NOT widened, unlike apple/jug: 40px raw is
; already far wider than one WALK_STEP, so nothing here is unreachable.
LOAF_BOX_X      equ 56
LOAF_BOX_Y      equ 64
LOAF_BOX_W      equ 160
LOAF_BOX_H      equ 16

; T0040: proxpicture (X-ALL.TXT ~3270), room 52's look-at-picture spot.
; raw x=62,y=104,w=5,h=16 -> X=(62-32)*4=120, same transform as every
; other box above; y/w/h unchanged.
PICTURE_BOX_X   equ 120
PICTURE_BOX_Y   equ 104
PICTURE_BOX_W   equ 20
PICTURE_BOX_H   equ 16

; T0105: proxcroc (X-ALL.TXT ~2805) -- raw room 53, x=68,y=140,w=10,h=20,
; through the same transform every other box here uses: X=(68-32)*4=144,
; W=10*4=40, y and h unchanged.
CROC_PROX_X     equ 144
CROC_PROX_Y     equ 140
CROC_PROX_W     equ 40
CROC_PROX_H     equ 20

FRAME_APPLE     equ 17
FRAME_ROPE      equ 14     ; ropehere, room 68
FRAME_JUG       equ 19
FRAME_LOAF      equ 20
FRAME_RAILING   equ 192    ; T0056: room 52's removable railing section
FRAME_WHISKEY   equ 18     ; T0068: room 53's bottle (whiskeyhere)
FRAME_POTION    equ 15     ; T0133: sleepingpotionhere, room 45 (not built)
FRAME_CROWBAR   equ 4      ; T0133: crowbarhere, room 88 (not built)
; T0201: frames of the other carryables in BUILT rooms, from
; extracted/actors.json (each one's `message` field names the original's
; own string, so the text is the source's, not invented).
FRAME_BEAN      equ 2      ; beanhere, room 22
FRAME_BUCKET    equ 5      ; buckethere, room 83
FRAME_BONE      equ 6      ; bonehere, room 100
FRAME_COW       equ 7      ; room 58
FRAME_PICKAXE   equ 9      ; room 87
FRAME_HOLE      equ 11     ; room 72
FRAME_LEAVES    equ 206    ; room 59
FRAME_ROCK1     equ 136    ; rockmess, room 53
FRAME_ROCK2     equ 138    ; rockmess, room 50
FRAME_ROCK3     equ 139    ; rockmess, room 35

gameplay_init
        clr killed
        clr troll_bribed
        clr rat_dir
        lda #16
        sta rat_step
        clr troll_launching
        clr dizzy_dir             ; T0136: latched direction / jump cycle
        clr jump_on
        clr jump_anim
        clr rat_target_active
        clr rat_fled
        ; T0114: game over now starts a NEW game in the same run, so every
        ; bit of progress that lives outside the actor table has to be put
        ; back here too (the actor table, inventory and coins are
        ; actors_init's).
        clr dragon_swing
        clr dragon_delay
        clr dragon_asleep
        clr dragon_fire
        clr troll_greeted
        clr troll_cooldown
        clr apple_msg_pending
        clr jug_quenched_msg_pending
        clr ratloaf_msg_pending
        clr fireout               ; T0216: the SECOND cause of the playtest's
                                   ; "the fire on the first room" -- proxjugrou
                                   ; sets this when the jug douses room 36's fire
                                   ; pit and nothing ever cleared it, so a brand
                                   ; new game started with the fire already out,
                                   ; both visually (draw_fire_overlay) and as a
                                   ; hazard (update_fire_hazard gates on it).
                                   ; T0214's cache fix was a different symptom.
        clr denzil_gave_rope      ; T0215: T0199's one-shot. Progress outside the
                                   ; actor table, which is exactly what this
                                   ; routine's own T0114 comment says belongs
                                   ; here -- without it Denzil has already handed
                                   ; over the rope in a brand new game.
        clr death_msg
        clr death_msg+1
        clr up_dc
        rts

; rat_newdir: picks a new random countdown (16-31, matching the
; original's own `and 15 / add a,16` exactly) and flips rat_dir.
;
; `rng_ctr` used to be a plain free-running counter (`inc` once per
; pass). PROVABLY WRONG, not just "not very random": this routine is
; itself called once every `rat_step` passes, i.e. exactly `rat_step`
; increments after the previous call -- and adding 16 never changes a
; value's low 4 bits, so with r = the previous (rng_ctr AND 15), the
; next sample is (r + rat_step) AND 15 = (r + r + 16) AND 15 = (2r) AND
; 15. That is a doubling map mod 16, which is DEGENERATE: iterating
; r -> 2r mod 16 from any starting value reaches 0 within at most 4
; calls and then stays there forever (0 -> 0), collapsing rat_step to
; its minimum (16) permanently. Real playtest: "the length of the path
; is stuck at a very small interval" -- this is exactly that collapse,
; not a tuning issue.
;
; Fixed by replacing the plain counter with a real (if tiny) 8-bit
; Galois LFSR (`rng_step`, room36.asm's mainloop, taps 0xB8 for a
; maximal 255-value period before repeating) -- its recurrence is
; linear over GF(2) rather than simple arithmetic doubling, so stepping
; it a state-DEPENDENT number of times per call doesn't reduce to a
; closed-form collapse the way plain addition did.
;
; T0162: the routine itself moved to target/rat_troll_hazard_code.asm,
; staged to CODE_DEST (block D), alongside update_rat -- see that
; file's own header. This comment (the RNG-derivation writeup) stays
; here; the code does not duplicate it.

; --------------------------------------------------------------------
; kill_dizzy: A = nonzero to start the death countdown (matches the
; original's `killed` semantics -- a countdown, not a boolean). Does
; nothing if a death is already in progress, same as the original's
; `ret nz` guard.
; --------------------------------------------------------------------
; T0058: kill_dizzy_msg takes X = a hazard-specific message stream,
; printed INSIDE the same box as `deadwindow` -- which is exactly what
; the original does: `killdizzy` is entered with HL pointing at
; croceatenmess/killedbyflame/ratgotyoumess and prints deadwindow (a
; box with "@orig(X-ALL:991/16)") followed by that text. The T0034 note
; here said wiring this up was out of scope then; the crocodile is the
; first hazard with a message worth reading, so it is wired now.
kill_dizzy
        ldx #0                   ; no hazard-specific line
kill_dizzy_msg
        pshs x
        lda killed
        bne kd_already
        lda #KILL_COUNTDOWN
        sta killed
        jsr play_killed          ; T0109: sndfx 25, same spot as the source
        puls x
        stx death_msg
        rts
kd_already
        puls x
        rts

; --------------------------------------------------------------------
; update_death: called once per mainloop pass. Counts `killed` down to
; 0, then respawns at the fixed start point and costs a life.
;
; T0034: the original (X-ALL.TXT ~1370, `nextlife`/`subfromlives`) shows
; `deadwindow` ("@orig(X-ALL:991/16)" + a hazard-specific quip) and blocks on
; `waitforkey` on EVERY death, then only loops back to `nextlife` (i.e.
; keeps playing) `if lives != 0` -- at 0 lives it falls through to
; `quitted` (flips back to the title screen) instead. This port has no
; title screen to fall back to (a vertical slice, not the full game), so
; there's nothing faithful to reproduce for that specific fallthrough --
; but silently refilling lives to 3 and respawning with NO acknowledgment
; at all (the previous behaviour here) isn't what the original does
; either: it always shows something and always blocks for a keypress.
; Real playtest: "lives currently wraps 3->0->3 with no end state".
;
; Fixed in two parts: `msg_deadwindow` (below) is the original's own
; `deadwindow` text, shown+dismissed on every death, same as the source
; -- this port had never shown anything on death before now. The
; hazard-specific second line the original also shows (killedbyflame for
; the flame hazard, ratgotyoumess for the rat -- both real, both
; findable in X-ALL.TXT) isn't wired up: `kill_dizzy`'s callers don't
; currently pass which hazard killed Dizzy through to here, and adding
; that parameter is out of this task's scope.
;
; T0114: the port's own `msg_gameover` box and its refill-and-respawn were
; removed here, in favour of returning to the title screen at 0 lives, the
; original's own ending.
;
; T0146: reversed. The user chose a TEXT "GAME OVER" screen over the title
; screen return -- a deliberate memory trade, not a fidelity fix (X-ALL.TXT
; itself goes back to the title on `quitted`): the title's gathered packed
; stream (TITLE_LZ_BUF, ~3.8KB) only had to stay resident so show_title
; could be re-entered at game over, and with the title never shown again
; after boot that stream can be boot-transient instead, freeing its space
; for the room image. `msg_gameover` (below) is T0034's original invention,
; revived unchanged -- same box footprint as `msg_deadwindow` so it fully
; overdraws with no stray fragments.
; --------------------------------------------------------------------
; msg_box_done (T0221): "print the box at X, block until the player
; dismisses it, then repaint both buffers whole" -- the three-call tail that
; followed nine different message boxes. 9 bytes inline, 3 as a call. X is the
; message stream, exactly as prtmessage wants it; nothing here disturbs it.
msg_box_done
        jsr prtmessage
        jsr msg_wait_dismiss
        jsr force_redraw
        rts

update_death
        lda killed
        beq gp_ud_done
        deca
        sta killed
        bne gp_ud_done

        jsr msg_begin
        ldx #msg_deadwindow
        jsr prtmessage
        ldx death_msg             ; T0058: the hazard's own line, into the
        beq gp_ud_nohazmsg        ; same box, as `killdizzy` does
        jsr prtmessage
gp_ud_nohazmsg
        ldx #0
        stx death_msg
        jsr play_deathtune       ; T0109: tune 2 -- X-ALL.TXT `finishmusic`
                                  ; straight after printing killedmess, so the
                                  ; box is already on screen while it plays
        jsr msg_wait_dismiss

        ; T0114/T0146: X-ALL.TXT, after the death box's waitforkey:
        ;   ld a,(lives) / and a / jp nz,nextlife   -- spare life: use it
        ;   quitted ... jp titlescreen               -- none left: title
        ; This port shows msg_gameover (T0146: text, not the title) instead
        ; of `quitted`'s title-screen flip, then starts a new game.
        if INF_LIVES
        bra gp_ud_respawn         ; playtest aid (./play.sh --inf-lives): never costs a life
        else
        lda lives
        beq gp_ud_gameover
        deca
        sta lives
        bra gp_ud_respawn
        endif
gp_ud_gameover
        ; T0231: TAPE_ROOMS builds restore X-ALL.TXT fidelity here --
        ; `quitted` does `jp titlescreen` -- via the resident title copy
        ; in the tape-only region (boot_code.asm's show_title_resident).
        ; The -run build (TAPE_ROOMS=0) is UNCHANGED: T0146's msg_gameover
        ; text box, byte-for-byte, because it has no resident title
        ; stream to replay (T0146 freed it for room image space).
        if TAPE_ROOMS
        jsr show_title_resident
        jmp new_game
        endif
        ; T0146: msg_wait_dismiss already waits out a still-held SPACE
        ; before arming for a fresh press (fb_waitspacerelease), so unlike
        ; the old show_title_again path there is no need for a separate
        ; ti_release call here.
        jsr msg_begin
        ldx #msg_gameover
        jsr prtmessage
        jsr msg_wait_dismiss
        jmp new_game              ; fresh game; resets the stack
gp_ud_respawn
        lda respawn_room          ; T0050: starteggres -- back to wherever
        sta cur_room               ; this room was entered, not to a fixed
        jsr load_room              ; point in the dungeon
        lda respawn_x
        sta dizzy_x
        lda respawn_y
        sta dizzy_y
        clr dizzy_dy
        clr dizzy_floor
        clr dizzy_seq             ; T0059: out of the keel-over sequence
        clr dizzy_anim
        ; T0125: starteggres also zeroes the latched left/right keys and
        ; obstructinglift. This port's stand-ins for the latched keys are the
        ; troll knockback and the well sequences: a Dizzy who died mid-launch
        ; came back still drifting left with the keys ignored until he landed.
        clr troll_launching
        clr well_mode
        clr ul_obstruct
        clr dizzy_dir             ; T0136: the latched left/right proper --
        clr jump_on               ; he respawns in the air, where nothing
        clr jump_anim             ; re-reads the keys until he lands
        ; T0089: X-ALL.TXT's `nextlife` calls starttune 1 right here,
        ; immediately after starteggres -- the real "new life" jingle.
        ldd #tune1_notes
        jsr play_tune
        jsr force_redraw       ; T0221 (was 8 bytes inline)
gp_ud_done
        rts

; --------------------------------------------------------------------
; aabb_hit: does the box (bx,by,bw,bh) -- pixel coords, in ah_bx etc --
; overlap Dizzy's FULL sprite footprint? Z clear on overlap.
;
; Deliberately NOT the narrowed BODY_L/BODY_R wall-collision box: these
; proximity triggers are often narrower than that inset alone (the
; apple's box is 4px wide; BODY_L+BODY_R already eats 23 of Dizzy's
; 24px width), which made the apple trigger geometrically impossible to
; reach -- found by live-poking dizzy_x/y and watching troll_bribed
; never flip (NOTES.md T0029-32). The original doesn't have this
; problem because its proximity check compares against Dizzy's real
; frame width (`findfrmsize`), not a narrowed movement box -- this
; fixes the same mismatch by using the full 24px sprite width here too.
; --------------------------------------------------------------------
; aabb_test (T0221): "A is the box height -- store it and run the overlap
; test", the three-instruction preamble that preceded ten of the eleven
; aabb_hit calls. 7 bytes inline, 3 as a call. `rts` does not touch CC, so the
; Z flag `tsta` sets here reaches the caller's beq/bne exactly as before;
; callers that read A itself still get aabb_hit's 1/0.
aabb_test
        sta ah_bh
        jsr aabb_hit
        tsta
        rts

aabb_hit
        ; horizontal: box_x < dizzy_right && dizzy_left < box_x+box_w
        ; T0138: both right edges SATURATE at 255. dizzy_x+24 wrapped to 0
        ; for x>=232, so nothing at the right edge of a room could burn,
        ; drown or trigger (room 68's fireplace flames at x=224..236).
        lda ah_bx
        adda ah_bw
        bcc ah_boxr
        lda #255
ah_boxr sta ah_tmp                ; box right edge
        lda dizzy_x
        adda #24                  ; Dizzy's full sprite width
        bcc ah_dizr
        lda #255
ah_dizr cmpa ah_bx
        bls aabb_miss              ; Dizzy right edge at/left of box left
        lda dizzy_x
        cmpa ah_tmp
        bhs aabb_miss              ; Dizzy left edge at/right of box right

        ; vertical: box_y < dizzy_feet && dizzy_head < box_y+box_h
        lda ah_by
        adda ah_bh
        sta ah_tmp                 ; box bottom edge
        lda dizzy_y
        cmpa ah_by
        bls aabb_miss              ; Dizzy feet at/above box top
        lda dizzy_y
        suba dizzy_h
        cmpa ah_tmp
        bhs aabb_miss              ; Dizzy head at/below box bottom
        lda #1
        rts
aabb_miss
        clra
        rts

; T0219: inv_has and inv_remove were removed here -- 130 bytes of provably
; dead resident code (verified: each appeared only at its own definition
; across every target/*.asm). The port had TWO bytes of title-hole spare and
; three verified fixes queued behind the delivery budget, so dead code was
; the cheapest place to find them. Both are in git if a future item puzzle
; wants them back; inv_remove's own comment said "used once the jug/apple
; are consumed by their puzzles", which never landed.

; --------------------------------------------------------------------
; update_rat: the one live actor with real per-frame behaviour in this
; slice. Patrols back and forth (rat_step counts down, direction flips
; at 0 -- a simplification of the original's oldmovex/oldmovey bounds
; check, same visible effect: a short back-and-forth walk) and kills
; Dizzy on contact via the shared actor_hit AABB test.
;
; Finds the rat by routine id, not a hardcoded slot index -- robust to
; actor_data.asm's slot order changing on a re-extraction.
; --------------------------------------------------------------------
; T0162: update_rat, rat_newdir and find_loaf_and_eat moved to
; target/rat_troll_hazard_code.asm, staged to CODE_DEST (block D) --
; same reasoning as update_crocodile/update_portcullis above. Its
; own call site (room36.asm mainloop's `jsr update_rat`) is
; unchanged; staged_syms.asm resolves the symbol. Covered by
; harness/actorlife.lua's rat assertion.

; --------------------------------------------------------------------
; troll_blocks: called from the horizontal-movement code (room36.asm)
; at the SAME point `check_wall` is -- with `try_x` set to the
; candidate position -- so the troll behaves as a REAL, consistent
; obstacle instead of a reactive push. Z clear = movement refused.
;
; This replaces an earlier "overlap it, then get shoved back 4px"
; design: real playtesting found the shove inconsistent (it visibly
; fired once, then looked like nothing happened on further attempts,
; because after one push Dizzy was already outside the box and had to
; be RE-OVERLAPPING for another push to fire -- fragile and confusing).
; A hard block at the collision-check level can't have that problem:
; either the candidate x overlaps the troll's box or it doesn't, every
; single time, the same way a real wall's `check_wall` already works.
;
; The message is edge-triggered on `troll_bump_shown` -- shown once per
; approach, not once per blocked frame (he'll be blocked every frame
; he keeps pressing into it) -- and re-arms once he backs away far
; enough to stop being blocked. Messages now wait for a keypress to
; dismiss (see flip_buffer), so there is no need for the old numeric
; cooldown timer at all.
;
; update_apple_bribe: giving the apple while inside the apple's own
; proximity box (proxapple) consumes it and clears the block --
; ld (ix+movex),255 in the original (the apple actor is removed) plus
; setting the troll's bribed state.
; --------------------------------------------------------------------
; --------------------------------------------------------------------
; update_troll: a REAL physics knockback, not a position nudge -- this
; was the actual gap, found only after a real playtest described it
; precisely ("thrown back through the air and tumbled back"). Two
; earlier attempts both missed the original's actual mechanic
; (proxtrollrou, X-ALL.TXT ~3359): `dy=-9` (launch upward), `sequence=4`
; (the jump-LEFT/tumble animation table), and `call checkkeys ;;resets
; left & right` (suppress player input for the duration). This is a
; real jump with real gravity, not a scripted animation -- it reuses
; this port's own existing jump/gravity code (JUMP_DY, dizzy_dy,
; dizzy_floor) entirely; nothing new was needed there.
;
; `dizzy_dir` is forced to 1 (left) at launch so the mainloop's own
; per-frame seq computation (`airborne-base(3) + dizzy_dir` = seq4,
; "jump left") naturally selects the tumble animation without this
; routine needing to touch `dizzy_seq` directly -- and `troll_launching`
; (checked in room36.asm's own movement code) is what actually
; suppresses input for the duration, matching `checkkeys` resetting
; left/right in the original. Clears itself on landing (ml_landed).
;
; The message is DELIBERATELY DROPPED here, not just delayed: this
; port's messages block the whole mainloop waiting for a keypress
; (T0029 follow-up), which is fundamentally incompatible with a
; physics animation playing out over several frames -- triggering it
; mid-launch is exactly what produced the reported "freezes waiting
; for the animation" bug. The launch itself is strong, immediate
; feedback; the flavour text is a smaller loss than a frozen tumble.
; --------------------------------------------------------------------
; T0162: update_troll moved to target/rat_troll_hazard_code.asm,
; staged to CODE_DEST (block D) -- same reasoning as
; update_crocodile/update_portcullis above. Its own call site
; (room36.asm mainloop's `jsr update_troll`) is unchanged;
; staged_syms.asm resolves the symbol. Covered by
; harness/actorlife.lua's new troll assertion (T0162).

; --------------------------------------------------------------------
; check_drop_triggers: A = drop_slot (the just-dropped actor's index+1,
; same convention drop_to_world uses -- called from there directly, so
; EVERY drop gets checked uniformly: the deliberate choice, the auto-
; drop-oldest-item-when-full path, and show_inventory's own selection).
;
; Replaces update_apple_bribe/update_jug_escape, both of which were
; wrong in the SAME way, confirmed against the real game twice by the
; user (once for the apple, once -- with a screenshot -- for the jug):
; they fired on "carrying the item AND overlapping a box", when the
; source's real proxapplerou/proxjugrou fire on the DROPPED item's own
; placed position overlapping that box. dropobject in X-ALL.TXT places
; a dropped item near Dizzy and its caller immediately re-checks
; proximity -- point_in_box below against the position drop_to_world
; JUST placed the item at is this port's equivalent.
;
; The jug/fire outcome was ALSO wrong beyond the trigger condition: it
; transitioned to room 35 as an invented stand-in for "escaping the
; dungeon". The source does no such thing -- proxjugrou just sets
; fireout and shows the message; Dizzy stays exactly where he is.
; Confirmed with a screenshot of the real game: "the fire is out but
; you are in the same place, instead of ... being teleported".
; --------------------------------------------------------------------
; T0054: item proximity triggers, rebuilt to match the original's actual
; mechanic. This used to fire at the MOMENT OF THE DROP, testing where the
; dropped item LANDED against the box. That is not what the original does,
; and two playtest reports in a row were the consequence:
;   "I have to drop the apple on top of the troll for it to work, and if I
;    get a pixel or 2 closer to the gate I get a knock back"
;   "the water jug seems to not be working now as well"
;
; What X-ALL.TXT really does (`checkproximity`/`checkproximity1` ~5963,
; `proximitycollide`/`joinprox` ~1923/1991):
;   - every LIVE actor carries a pointer to a proximity-box record, and
;     its own per-tick routine checks that box -- so the check runs
;     continuously while the item is lying in the room, not once;
;   - the box is tested against DIZZY (`ld a,(x) / add a,32` and
;     `ld a,(y) / sub eggheight`), never against the item.
; A carried item has room=255 and its routine never runs, so "dropped"
; is what arms the trigger, and standing in the box is what fires it.
;
; The difference in feel is the whole complaint. Testing the item's
; landing spot meant the apple had to come to rest inside a 16px box that
; sits underneath the troll -- so the only position that worked was the
; single step where Dizzy's own box just clears the troll's, and one step
; further in launched him instead. Testing DIZZY against the same box
; gives the source's own comfortable range (x=164-196 for the apple,
; which begins well before the troll's zone starts at 180), because
; Dizzy is 24px wide and contributes his own width to the overlap.
update_item_triggers
        ldy #actor_ram
        lda #ACTOR_COUNT
        sta uit_n
uit_loop
        lda ,y                   ; room -- 255 means carried, so no check
        cmpa cur_room
        bne uit_next
        lda 1,y
        cmpa #ROU_PICKUPABLE
        bne uit_next
        lda 4,y                  ; frame decides which box, as before
        cmpa #FRAME_APPLE
        lbeq uit_apple
        cmpa #FRAME_JUG
        lbeq uit_jug
        cmpa #FRAME_LOAF
        lbeq uit_loaf
uit_next
        leay ACTOR_STRIDE,y
        dec uit_n
        bne uit_loop
        rts

uit_apple
        lda cur_room
        cmpa #36
        lbne uit_next
        lda troll_bribed
        lbne uit_next
        lda #APPLE_BOX_X
        sta ah_bx
        lda #APPLE_BOX_Y
        sta ah_by
        lda #APPLE_BOX_W
        sta ah_bw
        lda #APPLE_BOX_H
        sta ah_bh
        jsr uit_hit
        tsta
        lbeq uit_next
        lda #255
        sta ,y                     ; the troll keeps it (proxapplerou's
        lda #1                      ; own `ld (ix+movex),255`)
        sta troll_bribed
        sta apple_msg_pending
        jsr force_redraw       ; T0221 (was 8 bytes inline)
        lbra uit_next

uit_jug
        lda cur_room
        cmpa #36
        lbne uit_next
        tst fireout
        lbne uit_next
        lda #JUG_BOX_X
        sta ah_bx
        lda #JUG_BOX_Y
        sta ah_by
        lda #JUG_BOX_W
        sta ah_bw
        lda #JUG_BOX_H
        sta ah_bh
        jsr uit_hit
        tsta
        lbeq uit_next
        lda #255
        sta ,y                     ; consumed by the fire
        lda #1
        sta fireout
        sta jug_quenched_msg_pending
        jsr force_redraw       ; T0221 (was 8 bytes inline)
        lbra uit_next

uit_loaf
        lda cur_room
        cmpa #36
        lbne uit_next
        tst rat_fled
        lbne uit_next
        tst rat_target_active
        lbne uit_next               ; already armed -- don't re-arm every pass
        lda #LOAF_BOX_X
        sta ah_bx
        lda #LOAF_BOX_Y
        sta ah_by
        lda #LOAF_BOX_W
        sta ah_bw
        lda #LOAF_BOX_H
        sta ah_bh
        jsr uit_hit
        tsta
        lbeq uit_next
        ; proxloafrou: the rat is sent to the LOAF's position, not Dizzy's
        lda 2,y
        sta rat_target_x
        lda #1
        sta rat_target_active
        lbra uit_next

; uit_hit: aabb_hit, with Y (the actor pointer) preserved across it.
uit_hit
        pshs y
        jsr aabb_hit
        puls y
        rts

; point_in_box: A=x, B=y -> Z clear if (A,B) lies within
; [ah_bx,ah_bx+ah_bw) x [ah_by,ah_by+ah_bh). A plain point test, not
; actor_hit's AABB -- callers here are checking one dropped item's
; single placed position, not two sprites' overlapping boxes.
point_in_box
        sta pib_px
        stb pib_py
        lda pib_px
        cmpa ah_bx
        blo pib_miss
        lda ah_bx
        adda ah_bw
        cmpa pib_px
        bls pib_miss
        lda pib_py
        cmpa ah_by
        blo pib_miss
        lda ah_by
        adda ah_bh
        cmpa pib_py
        bls pib_miss
        lda #1
        rts
pib_miss
        clra
        rts

; --------------------------------------------------------------------
; update_flame_hazard: the flame is drawn (T0026) but was never wired
; to kill on contact until now -- closes that gap explicitly.
; --------------------------------------------------------------------
; --------------------------------------------------------------------
; hazard_scan: shared by the flame and water hazards (T0032 follow-up
; added a second one -- factored rather than duplicated, same reason
; as `clear_and_blit`: bytes below the framebuffer are critically
; tight). Walks `uf_n` (x,y) pairs at `uf_ptr`, box size (uf_bw,uf_bh),
; kills Dizzy on the first overlap.
; --------------------------------------------------------------------
; T0162: update_flame_hazard/update_water_hazard/update_fire_hazard
; (and the hazard_scan they share) moved to
; target/rat_troll_hazard_code.asm, staged to CODE_DEST (block D) --
; same reasoning as update_crocodile/update_portcullis above. Their
; own call sites (room36.asm mainloop's `jsr update_flame_hazard` /
; `jsr update_water_hazard` / `jsr update_fire_hazard`) are unchanged;
; staged_syms.asm resolves the symbols. Covered by
; harness/actorlife.lua's new flame-hazard assertion (T0162).

; --------------------------------------------------------------------
; show_pending_messages: dialogue callers (T0029) -- the one-shot flags
; the routines above set are drained here, once per mainloop pass, into
; real prtmessage calls. Kept separate from where the flags are set so
; a hazard/puzzle routine never itself blocks on drawing a window.
; --------------------------------------------------------------------
; Three (flag, message pointer) pairs, dispatched through one shared
; show-and-flip loop -- memory is critically tight below the
; framebuffer (see NOTES.md), and repeating the same 6-instruction
; show+flip sequence three times over was pure waste.
spm_table
        fdb apple_msg_pending
        fdb msg_apple_given
        fdb jug_quenched_msg_pending
        fdb msg_jug_quenched
        fdb ratloaf_msg_pending
        fdb msg_ratloaf
; The troll's own message isn't in spm_table above: unlike these two
; (which really are fire-and-forget post-event messages), it's shown
; SYNCHRONOUSLY from inside update_troll itself, before the knockback
; state is even set up -- matching X-ALL.TXT's proxtrollrou exactly (see
; that routine's own comment). It needed its own deferred/gated path
; here in an earlier version of this fix, when it was (wrongly) shown
; only after landing; that whole mechanism is gone now that showing it
; up front sidesteps the reason it existed in the first place.

show_pending_messages
        ldx #spm_table
        lda #3                    ; entries in spm_table -- bump this
                                    ; whenever one is added, nothing
                                    ; derives it automatically
        sta spm_i
spm_loop
        ldu ,x                    ; U = this entry's flag address
        lda ,u
        beq spm_next
        clr ,u
        ldu 2,x                   ; U = this entry's message address
        pshs x
        tfr u,x
        jsr msg_chatter
        lda #1
        sta spm_shown
        puls x
spm_next
        leax 4,x
        dec spm_i
        bne spm_loop

        lda spm_shown
        ; A message box is much bigger than Dizzy's own damage rect, so
        ; the next redraw()'s small partial clear leaves most of it
        ; sitting in the framebuffer indefinitely -- it only ever LOOKS
        ; gone when a later buffer flip happens to show the OTHER
        ; buffer, then reappears again on the next flip back. Force
        ; both buffers to fully redraw once the message is done, same
        ; trick room transitions and item pickup already use.
        lda spm_shown
        beq spm_done
        clr spm_shown
        jsr force_redraw       ; T0221 (was 8 bytes inline)
spm_done
        rts

; msg_begin / msg_wait_dismiss: draw a message box straight onto the
; VISIBLE page and hold it there until the player presses SPACE.
;
; This pair replaces an earlier `flip_buffer`, whose whole premise was
; wrong and cost several rounds of playtesting to pin down. It assumed
; prtmessage had drawn into the OFF-screen buffer, so it flipped to show
; that buffer. But `redraw` ENDS by flipping to display what it just
; drew (see its own comment on vsync-synced flipping) -- so by the time
; any message caller runs, `draw_base` already points at the page that
; is ON SCREEN. prtmessage therefore drew the box onto the visible page
; (briefly visible -- "the message pops up momentarily"), and the flip
; then swapped to the OTHER page, which has no box in it at all. The
; box vanished instantly, every time, while the game correctly went on
; blocking for the dismiss key.
;
; That bug also survived a bogus verification: a framebuffer dump
; "proved" the box persisted for 9 seconds, yet it was reading $6000
; while cur_buf==0, and cur_buf==0 means $4000 is the displayed page.
; It was reading the off-screen buffer -- exactly where the orphaned
; box really did sit forever, untouched. The dump confirmed the bug and
; was misread as clearing it.
;
; With no double-buffering in play the box is painted directly onto the
; live page, glyph by glyph, which is what the Spectrum original does
; too (it has no page flipping at all). The game is frozen for the
; duration anyway, so there is nothing to tear against; callers force
; both buffers to fully redraw afterwards to clear the box away.
;
; msg_begin must be called BEFORE prtmessage: it points draw_base at
; the displayed page explicitly, rather than trusting the caller to run
; at a point in the frame where that already happens to be true.
msg_begin
        clr fb_flip              ; T0125: boxes are never upside down
        jsr play_boxopen         ; T0109: sndfx 6, drawboxrou -- every box
        jsr wait_vsync           ; start painting just after a field, not mid-scan
        lda cur_buf
        bne mb_showingb
        ldd #BUFA                ; cur_buf==0 -> $ffce was written -> A is live
        std draw_base
        rts
mb_showingb
        ldd #BUFB                ; cur_buf==1 -> $ffcf was written -> B is live
        std draw_base
        rts

; --------------------------------------------------------------------
; msg_chatter -- X-ALL.TXT's `chatter` (line 2402). Shows a SEQUENCE of
; message boxes, one at a time, each dismissed by the player, until a
; second `mend` ends the run:
;
;   chatter  ld a,1
;            ld (dontupdatedizzy),a
;            call printandwait   ;; print one box + wait; HL ends past mend
;            ld a,(hl)
;            and a               ;; another message follows?
;            jr nz,chatter
;            jp windowrou1
;
; Ports directly, because our prtmessage leaves X past the terminating 0
; for exactly the same reason the Z80's HL does.
;
; This is a real distinction in the original, not a detail: `windowrou`
; shows ONE box and is what almost everything uses, while `chatter` is
; reserved for the two actual conversations (trollgotapplemess and
; knockandentermess). Missing it is why giving the troll the apple showed
; a single box here instead of the original's four-box exchange. Any
; stream driven through this routine must end with TWO zero bytes -- one
; closing the last message, one ending the run. See NOTES.md T0030.
; --------------------------------------------------------------------
msg_chatter                      ; X -> message stream (1 or more boxes)
mc_loop
        pshs x
        jsr msg_begin
        puls x
        jsr prtmessage           ; leaves X just past this message's mend
        pshs x
        jsr msg_wait_dismiss
        puls x
        lda ,x                   ; peek: another box, or end of the run?
        bne mc_loop
        rts

msg_wait_dismiss
        ; T0154: a real state byte for the harnesses. They used to detect
        ; "a box is up" by scanning raw stack bytes for anything resembling
        ; a return address into this routine -- an unaligned scan with no
        ; frame validation, so adjacent bytes forming a plausible value read
        ; as a false positive. exits_port.lua's busy() livelocked on exactly
        ; that once DEBUG_PROX_KEYS put another routine in the mainloop's
        ; call graph, which meant the SHIPPED build could not be the TESTED
        ; build. One byte here beats any stack heuristic.
        lda #1
        sta msg_active
        ; Hold the message up until the player actually dismisses it,
        ; rather than a fixed timer -- real playtest feedback: a short
        ; auto-hide made messages flash past unread.
        ;
        ; NOTE: none of the dismiss-detection history below was ever
        ; the actual cause of "the box shows up and disappears straight
        ; away, before I can read it" -- that was msg_begin's bug (see
        ; its own comment): the box was being painted onto the visible
        ; page and then immediately flipped away to a page that never
        ; had it. This routine's own job -- correctly WAITING once the
        ; box is actually staying on screen -- was working the whole
        ; time. Keeping this history because the SPACE-key approach is
        ; still the right call independent of that bug (a real keyboard
        ; can auto-repeat), not because it was what fixed the vanishing.
        ;
        ; Went through two more attempts before this one, both trying
        ; to dismiss on "any movement key", which turned out to be the
        ; wrong idea entirely:
        ;   1. Wait for a full release (keyflags==0) before waiting for
        ;      a fresh press -- fails the instant a message can appear
        ;      while input is being ignored anyway (the troll knockback),
        ;      since the player then has no reason to ever let go.
        ;   2. Snapshot which keys were held when the message appeared
        ;      and dismiss on any bit OUTSIDE that baseline. Verified
        ;      correct against every scripted MAME test (including a
        ;      clean 10-second hold of one key with nothing else
        ;      touched -- never a false dismiss), and byte-identical
        ;      framebuffer reads proved the box itself was never being
        ;      silently erased. But real interactive play still saw it
        ;      "disappear straight away" -- almost certainly because a
        ;      REAL keyboard's OS-level auto-repeat resends keydown
        ;      events for a key that's simply being held, which looks
        ;      identical to "a genuinely new key" from inside the
        ;      emulated matrix. A scripted ioport hold in MAME can't
        ;      reproduce that, which is exactly why it passed every
        ;      automated test and still failed for a real player.
        ;
        ; Fixed properly by making dismissal unambiguous instead of
        ; clever: SPACE, which scankeys/keyflags didn't read at all
        ; before this, is used for nothing else anywhere in this port.
        ; A player has no reason to be holding or repeating it during
        ; normal movement, so auto-repeat noise on the movement keys
        ; can no longer matter, whatever the real cause of that noise
        ; turns out to be.
        ;
        ; Each poll is paced to one per video frame (wait_vsync) and
        ; requires the reading to REPEAT before it counts -- a previous
        ; version polled scankeys in a tight loop at full CPU speed, and
        ; a real playtest saw messages "pop up for a split second and
        ; then they are gone": scankeys samples $FF00 immediately after
        ; selecting a column, and at thousands of polls/sec a single
        ; unstable read was enough to satisfy "a key went down" and tear
        ; through in microseconds. Pacing to 60Hz plus requiring two
        ; consecutive agreeing reads makes a transient impossible to
        ; mistake for a real press.
fb_waitspacerelease
        jsr fb_stablekeys
        bita #16
        bne fb_waitspacerelease   ; SPACE already down -- wait it out first
fb_waitspacepress
        jsr fb_stablekeys
        bita #16
        beq fb_waitspacepress
        clr msg_active           ; T0154
        rts

; fb_stablekeys: A = keyflags, but only after two consecutive frame-
; paced reads agree. Returns the agreed value.
fb_stablekeys
        jsr wait_vsync
        jsr scankeys
        lda keyflags
        sta fb_k1
        jsr wait_vsync
        jsr scankeys
        lda keyflags
        cmpa fb_k1
        bne fb_stablekeys        ; disagreed -- sample again
        rts

; --- state ------------------------------------------------------------
; T0161: update_crocodile (X-ALL.TXT's crocodilerou, room 53) moved to
; target/croc_portcullis_code.asm, staged to CODE_DEST (block D) the
; same way T0148 moved update_dragon -- see that file's own header for
; the full writeup, the locals it took with it (uc_n/uc_slot), and why
; it's safe. Its own call site (room36.asm mainloop's `jsr
; update_crocodile`) is unchanged; staged_syms.asm resolves the symbol.
; Covered by harness/actorlife.lua's croc assertion.

; --------------------------------------------------------------------
; T0068: room 51's gate (@orig(X-ALL:453/20)). X-ALL.TXT's
; `portcullisrou`/`portswitchrou` (~3186/3208).
;
; T0115 (replacing T0068/T0102's reading, which the real game disproved --
; filmed and RAM-logged in MAME with harness/zx_film.lua):
;
; The gate is one 8x8 sprite (frame 120, bottom two rows blank) drawn in
; OVERWRITE mode and never erased. At rest it is CLOSED: on room entry
; resetportcullis draws it at every 2px step from y=96 down to 136, a
; lattice column (draw_gate). Nothing moves until the SWITCH (frame 122,
; a separate actor) is thrown -- press DOWN near it once, one-shot (the switch-throw
; message, X-ALL.TXT 880-881). Then, forever:
;
;   rises 2px per 2 ticks to y=96   -- the blank rows erase the bottom:
;                                      the gate OPENS from below
;   slams 2px per tick back to 136  -- closes, killing Dizzy on contact
;   rises 2px per 4 ticks to 96     -- reopens slowly, and round again
;
; Collision is the drawn column (build_solid_actors): solid when closed,
; walkable underneath when raised.
;
; T0161: update_portcullis (the state machine above) moved to
; target/croc_portcullis_code.asm, staged to CODE_DEST (block D) --
; same reasoning as update_crocodile above. draw_gate (below, UNMOVED --
; it is reached through the per-room draw table, not this single
; hardcoded call site) still needs PORT_OPEN_Y/PORT_CLOSED_Y, so those
; two equ stay resident here rather than moving with the code. Covered
; by harness/portcullis_block.lua.
; --------------------------------------------------------------------
PORT_OPEN_Y     equ 96     ; raised/open -- the source's own oldmovex field
PORT_CLOSED_Y   equ 136    ; lowered/closed -- the source's own oldmovey field,
                            ; also porthere's starting y


; --------------------------------------------------------------------
; draw_gate: T0115. Y = @orig(X-ALL:1000/14) actor record, called by draw_actors
; for every pass in room 51, active or not.
;
; The original draws the gate in OVERWRITE mode (colour 7: plot mode 0,
; X-ALL.TXT doplottype patches a NOP between `ld a,(iy+0)` and
; `ld (hl),a`) and never erases it. Frame 120 is 8x8 with its bottom two
; rows blank, so:
;   * resetportcullis, on room entry, draws it at every 2px step from y=96
;     down to its current y: a closed lattice column;
;   * rising 2px, the blank rows land on the old bottom edge and erase it:
;     the gate OPENS from below;
;   * falling 2px, the lattice lands lower: it closes.
;
; Frame 120 is exactly one byte wide and x=176 is byte-aligned, so every
; draw is 8 whole bytes down one framebuffer column: no blit needed.
;
; Per buffer (the two framebuffers alternate), remember the y last drawn
; there. Rising, draw every 2px step between it and the current y, since
; skipping one would leave two stale lattice rows; falling, the draw at the
; current y covers everything. If the damage rect touches the column --
; a full-screen invalidation (room entry, a message box), or room art
; restored around Dizzy -- redraw the whole resetportcullis column. That
; column is, row for row, sprite rows 0 and 1 alternating from y=96 down
; to y-1, then the sprite itself at y.
; --------------------------------------------------------------------
draw_gate
        lda 3,y
        sta dg_y
        lda 2,y
        lsra
        lsra
        lsra
        sta dg_col
        ldx #gate_last_a
        lda draw_base
        cmpa #$40
        beq dg_haveptr
        ldx #gate_last_b
dg_haveptr
        stx dg_lp
        lda ,x
        cmpa #255
        beq dg_full               ; never drawn into this buffer
        lda dg_col                ; column vs damage rect
        cmpa dmg_col1
        bhs dg_nodmg
        inca
        cmpa dmg_col0
        bls dg_nodmg
        lda #PORT_OPEN_Y
        cmpa dmg_y1
        bhs dg_nodmg
        lda dg_y
        adda #8
        cmpa dmg_y0
        bhi dg_full
dg_nodmg
        lda [dg_lp]
        cmpa dg_y
        beq dg_done               ; unchanged in this buffer
        blo dg_last               ; falling: one draw at y
dg_uplp
        suba #2                   ; rising: every step below the last one
        cmpa dg_y
        bls dg_last
        sta dg_s
        jsr dg_put
        lda dg_s
        bra dg_uplp
dg_full
        lda #FBWIDTH
        ldb #PORT_OPEN_Y
        mul
        addd draw_base
        addb dg_col
        adca #0
        tfr d,x
        ldb #PORT_OPEN_Y
        lda #$db                  ; frame 120 row 0; row 1 is $b6
dg_fill
        cmpb dg_y
        bhs dg_last
        sta ,x
        leax FBWIDTH,x
        eora #$db^$b6
        incb
        bra dg_fill
dg_last
        lda dg_y
        sta dg_s
        jsr dg_put
dg_done
        lda dg_y
        sta [dg_lp]
        rts

; dg_put: frame 120's 8 rows down column dg_col from row dg_s, overwriting.
dg_put
        lda #FBWIDTH
        ldb dg_s
        mul
        addd draw_base
        addb dg_col
        adca #0
        tfr d,x
        ldu #aspr_120
        ldb #8
dg_putlp
        lda ,u+
        sta ,x
        leax FBWIDTH,x
        decb
        bne dg_putlp
        rts

dg_y        fcb 0
dg_col      fcb 0
dg_s        fcb 0
dg_lp       fdb 0
gate_last_a fcb 255
gate_last_b fcb 255

; --------------------------------------------------------------------
; T0070: the dagger trap (room 69, `daggerrou` ~3395) @orig(X-ALL:922/14)
; (room 54, `dragonrou` ~2566).
;
; T0071: the dragon animated in full -- neck sway, fire-breath, and the
; proxsleep-triggered sleep/retract. X-ALL.TXT ~2540-2760.
;
; State (globals, not actor-slot fields -- there is only ever one
; dragon, so packing this into the 8-byte actor record the way the
; source overloads oldmovex/delaycounter/var1 buys nothing and just
; makes the fields harder to read):
;
;   dragon_swing   the source's `oldmovex` -- a triangle wave 0..16
;                  while awake (driven by dragon_delay), decrementing
;                  toward -8 once asleep. Head/neck Y all derive from
;                  this ONE value: headY = 152 - swing, and each neck
;                  segment b (1..6) sits at 152 - b*swing/8 (findnecky).
;                  At swing=0 every segment collapses to the same
;                  y=152 -- that is the source's own geometry, not a
;                  bug, and the neck visibly "uncurls" as swing rises.
;   dragon_delay   0..31, wraps; feeds the triangle wave (delay<16 ->
;                  swing=delay, else swing=32-delay).
;   dragon_asleep  latched by the proxsleep trigger. Once set AND
;                  swing has decremented all the way to -8, `update_
;                  dragon`/`draw_dragon` both stop touching the dragon
;                  AT ALL -- matching the source's own `cp -8/ret z`,
;                  which exits before printneck ever runs again. The
;                  LAST frame drawn (at swing=-8, head sunk to y=160,
;                  neck flattened downward) is simply left on screen
;                  forever after, exactly like any other static
;                  placement -- no explicit "hide" step exists in the
;                  source and none is needed here either.
;   dragon_fire    0 = not breathing. 1..47 = a breath in progress;
;                  increments every tick it's called (this port's own
;                  rate -- see T0061 on why a literal tick-for-tick
;                  match to the interrupt-driven original isn't the
;                  goal). While breathing, the NECK IS NOT DRAWN AT ALL
;                  (the source calls `dragonfire` INSTEAD of `printneck`
;                  once breathingfire != 0) -- only the head and the
;                  flame plume.
;
; Flame extent: `printdragonflame`'s own arithmetic (pos = frame*2 -
; dragon_fire + 68, visible only for 50<=pos<68) turns out to be a
; fully deterministic, precomputable "plume growing then retreating"
; sequence once simulated -- verified in Python before writing this,
; not guessed: dragon_fire 1-2 is a silent windup, 3-20 the plume grows
; from one puff to six sweeping outward, 21-30 it retreats, 31-47 is a
; silent cooldown before the cycle can restart. Reproduced here as a
; direct 6-iteration loop matching the source's own formula (cheap
; enough at 6 iterations, once every many seconds, that a precomputed
; lookup table wasn't worth the memory it would cost).
;
; What is NOT reproduced: the colour flip between yellow/red flame
; tones (`dragonfire`'s second `printdragonflame` pass, using the
; original's ATTRIBUTE plane) -- inert on this monochrome target the
; same way every other attribute byte already is, so replicating the
; flip logic would spend cycles changing an attribute nothing reads.
; --------------------------------------------------------------------
DRAGON_ORIGY    equ 152    ; the actor's own placed y (matches actor_init)
DRAGON_HEAD_X   equ 144    ; raw 68 -> (68-32)*4, fixed, never moves
DRAGON_SLEEP_X  equ 112    ; proxsleep: raw 60,150,10,30
DRAGON_SLEEP_Y  equ 150
DRAGON_SLEEP_W  equ 40
DRAGON_SLEEP_H  equ 30

; T0148: update_dragon + dragon_flames -- CODE *and* their own local
; variables (dgf_i through dragon_flame_x) -- moved out of here, staged to
; CODE_DEST ($8000+) and unpacked at boot -- see target/dragon_code.asm.
;
; The variables did NOT stay resident here, despite the earlier plan (this
; comment used to say so) -- a WALL, found by the emulator, not guessed:
; pass 1 (raw/STAGE_GEN) and pass 2 (packed/STAGE_LZ) assemble `start:`'s
; boot relocate/unpack code at DIFFERENT sizes (the STAGE_LZ branch's two
; `jsr lz_unpack` calls against the else branch's two byte-copy loops, 12
; bytes apart), which shifts `low_resume` -- and everything gameplay.asm
; defines after it, including these variables -- by that same 12 bytes
; between the two passes. Staged block D's BYTES are frozen from pass 1
; and never re-assembled for pass 2, so any absolute reference inside them
; to a LOW-memory address baked in from pass 1 is wrong by that gap in the
; real (pass 2) memory map. Block C and rooms 52/53 etc. never tripped
; this because they reference ONLY other staged-block labels (frozen
; together, consistent by construction); this is the first staged block
; that touched anything outside itself. Moving the variables into the same
; staged block (still just as self-contained) fixes it for the same reason
; CODE_DEST itself is stable across passes: their addresses now derive
; from CODE_DEST (BANNER_BUF minus a fixed CODE_BUDGET), not from
; low_resume. draw_dragon/dragon_necky (room36.asm, unmoved, resident
; code) still reach them by the same plain absolute addressing, just at
; their new $8000+ home -- see staged_syms.asm's explicit export list
; (tools/stage_pack.sh) for how pass 2 learns those addresses without
; re-assembling target/dragon_code.asm at all.
;
; T0153 note (retry): the pass1/pass2 boot-branch skew above is now FIXED
; AT SOURCE (both branches padded to equal size, 0 low-memory symbols
; move) -- this block's own workaround (keeping the variables staged, and
; exporting them via staged_syms.asm) remains correct and is kept;
; (it is no longer load-bearing for correctness the way it was when written.)

; The dagger IS implemented in full: it is genuinely simple in the
; source (one `collidewithdizzy16` test, no state at all) and its own
; quirk is worth keeping -- dying to it relocates the CHECKPOINT to a
; fixed spot (room 84, x=224, y=176) rather than the room's own natural
; entry point, `UNLESS` already in room 94 (`cp 94 / jr z,roomdagok`).
; Room 84 (@orig(X-ALL:486/20)) isn't built in this slice, so the
; override is gated on `room_exists` (T0067) -- same rule as an unbuilt
; neighbour: if the target isn't there, fall back to whatever checkpoint
; the room's own entry already set, rather than respawning into nothing.
; --------------------------------------------------------------------
; T0162: update_dagger moved to target/armorog_lifts_dagger_code.asm,
; staged to CODE_DEST (block D) -- same reasoning as update_crocodile/
; update_portcullis above. Its own call site (room36.asm mainloop's
; `jsr update_dagger`) is unchanged; staged_syms.asm resolves the
; symbol.

; (T0123's update_armorog moved to logic_low.asm in T0124: code+data was full.)

; --------------------------------------------------------------------
; T0075/T0133: room 55's well lid. update_welllid USED to fire
; proxcrowbarrou on mere proximity (any visit to the box, no held-item
; check). That was wrong: X-ALL.TXT only reaches proxcrowbarrou via
; `justexitinvent` -> checkproximity when the CROWBAR is dropped in the
; box. That trigger now lives in check_drop_trigger's cdt_crowbar branch
; (plus the debug key, DBG_WELL_KEY below) -- and since firing the
; trigger was the ONLY thing update_welllid ever did (no other per-frame
; state; `welllidhere` is a static actor, just set dressing until then),
; there is nothing left to call every frame. Routine removed, along with
; its call in room36.asm's mainloop. WELLLID_PROX_* constants are kept
; (check_drop_trigger's cdt_crowbar reuses them) but ROU_CROWBAR's old
; per-frame scan is gone.
; --------------------------------------------------------------------
WELLLID_PROX_X  equ 56
WELLLID_PROX_Y  equ 144
WELLLID_PROX_W  equ 32
WELLLID_PROX_H  equ 16

killed              fcb 0
death_msg           fdb 0
troll_bribed        fcb 0
rng_ctr             fcb 0    ; free-running, incremented in room36.asm's mainloop
ah_bx               fcb 0
ah_by               fcb 0
ah_bw               fcb 0
ah_bh               fcb 0
ah_tmp              fcb 0
troll_launching     fcb 0    ; set at launch, cleared on landing (room36.asm ml_landed)
apple_msg_pending   fcb 0
jug_quenched_msg_pending fcb 0
ratloaf_msg_pending fcb 0
uit_n               fcb 0
pib_px              fcb 0
pib_py              fcb 0
spm_shown           fcb 0
spm_i               fcb 0
fb_k1               fcb 0

; Real text, X-ALL.TXT trollgotapplemess -- was "TROLL:LIKES:APPLES",
; invented rather than transcribed. Also corrected the MECHANIC, not
; just the text -- see check_drop_triggers' own comment.
; Text positions below are COMPUTED (interior width/height from the box
; cell size, each line's real pixel width from its own character
; count), not eyeballed -- the earlier hand-picked values fit inside
; the box but were never actually centered in it (one line started
; before the interior edge, overlapping the border). Real playtest:
; "text is not properly centered". Same formula applied to all three
; message boxes in this file, not just the one that got screenshotted.
; X-ALL.TXT's `trollgotapplemess` (line 541), byte-for-byte, including
; its own box positions and sizes. FOUR boxes: proxapplerou does
; `jp chatter`, not `jp windowrou`, so this is a conversation, not a
; notification. Our earlier version had only box 1, with hand-invented
; coordinates that then needed hand-recentring -- copying the original's
; own numbers makes both problems go away, exactly as it did for the art.
;
; mpen=16, mxy=128, drawbox=9, mend=0 (X-ALL.TXT lines 4808-4819). The
; mpen bytes are inert on a 1bpp target but are kept so the stream stays
; byte-identical to the original's data.
msg_apple_given
        fcb 16+7,128+2,48,9,13,5,16+3
        fcb 128+11,72
        fcc "@orig(X-ALL:543/8)"
        fcb 128+10,80
        fcc "@orig(X-ALL:544/9)"
        fcb 128+7,88
        fcc "@orig(X-ALL:545/12)"
        fcb 0
        fcb 16+5,128+16,80,9,11,5,16+6
        fcb 128+23,104
        fcc "@orig(X-ALL:547/8)"
        fcb 128+22,112
        fcc "@orig(X-ALL:548/9)"
        fcb 128+22,120
        fcc "@orig(X-ALL:549/9)"
        fcb 0
        fcb 16+5,128+8,48,9,20,6,16+6
        fcb 128+16,72
        fcc "@orig(X-ALL:551/16)"
        fcb 128+16,80
        fcc "@orig(X-ALL:552/16)"
        fcb 128+14,88
        fcc "@orig(X-ALL:553/18)"
        fcb 128+15,96
        fcc "@orig(X-ALL:554/17)"
        fcb 0
        fcb 16+5,128+6,112,9,22,5,16+6
        fcb 128+13,136
        fcc "@orig(X-ALL:556/19)"
        fcb 128+14,144
        fcc "@orig(X-ALL:557/18)"
        fcb 128+11,152
        fcc "@orig(X-ALL:558/21)"
        fcb 0
        fcb 0                     ; second mend: ends the chatter run
; Real text AND real outcome, X-ALL.TXT throwwateronfiremess/
; proxjugrou -- was "YOU:ESCAPED:THE:DUNGEON" plus a room transition to
; 35, both invented. The source does neither: it just quenches the
; fire (fireout=1) and consumes the jug, Dizzy stays exactly where he
; is. Real playtest, with a screenshot of the real game proving it:
; "the fire is out but you are in the same place, instead of ... being
; teleported to the other room". See check_drop_triggers.
; X-ALL.TXT's `throwwateronfiremess` (line 841), byte-for-byte. Single
; box -- proxjugrou does `jp windowrou` -- but it goes through
; msg_chatter like everything in spm_table, so it carries the second
; mend that ends the run. Behaviour is identical either way for a
; one-box stream.
msg_jug_quenched
        fcb 16+7,128+2,48,9,21,6,16+3
        fcb 128+10,72
        fcc "@orig(X-ALL:843/17)"
        fcb 128+10,80
        fcc "@orig(X-ALL:844/17)"
        fcb 128+8,88
        fcc "@orig(X-ALL:845/19)"
        fcb 128+7,96
        fcc "@orig(X-ALL:846/20)"
        fcb 0
        fcb 0                     ; second mend: ends the chatter run

; X-ALL.TXT's `thanksforloafmess` (line 913), byte-for-byte. Single box
; -- ratcoll does `jp windowrou` -- shown via spm_table like the jug.
msg_ratloaf
        fcb 16+7,128+2,48,9,18,5,16+3
        fcb 128+8,72
        fcc "@orig(X-ALL:915/16)"
        fcb 128+11,80
        fcc "@orig(X-ALL:916/13)"
        fcb 128+11,88
        fcc "@orig(X-ALL:917/13)"
        fcb 0
        fcb 0                     ; second mend: ends the chatter run

; X-ALL.TXT's `getbackintheremess` (line 974), byte-for-byte. Single box
; (proxtrollrou does `jp windowrou` when roomno=36) and shown directly,
; not via spm_table, so one terminator.
;
; The leading '&' and trailing '\'' are RESTORED. A previous version
; dropped them because "their exact intended glyph isn't established" --
; it now is: rendering font glyphs 38 and 39 straight out of
; font_data.asm shows a matched pair of opening and closing speech
; marks, which is exactly what a quoted line of dialogue wants. The
; question was answerable by looking, and every '&...\'' pair in the
; original's message data is a spoken line.
msg_troll
        fcb 16+5,128+2,48,9,21,4,16+6
        fcb 128+10,72
        fcc "@orig(X-ALL:976/17)"
        fcb 128+7,80
        fcc "@orig(X-ALL:977/20)"
        fcb 0

; T0040: real text, X-ALL.TXT's own `lookatpicturemess` (line 848),
; byte-for-byte including its own box position/size. Triggered by
; `try_pickup` (see its own comment) reproducing `tryputtingdown`'s real
; gating: DOWN, while carrying something, standing in `proxpicture`'s
; box (X-ALL.TXT ~3270) -- not a separate always-available "examine"
; action. Doesn't consume or drop what's held, matching the source
; (`proxpicturerou` never touches the carried item at all).
msg_picture
        fcb 16+7,128+2,96,9,23,6,16+3
        fcb 128+11,120
        fcc "@orig(X-ALL:850/18)"
        fcb 128+9,128
        fcc "@orig(X-ALL:851/20)"
        fcb 128+10,136
        fcc "@orig(X-ALL:852/19)"
        fcb 16+5
        fcb 128+8,144
        fcc "@orig(X-ALL:853/21)"
        fcb 0

; T0034: real text, X-ALL.TXT's own `deadwindow` (line 990), byte-for-
; byte including its own box position/size -- see update_death's own
; comment for why this wasn't shown at all before now, and what's
; deliberately still missing (the hazard-specific second line).
msg_deadwindow
        fcb 16+6,128+10,64,9,18,6
        fcb 128+16,112,16+2
        fcc "@orig(X-ALL:991/16)"
        fcb 16+5
        fcb 0

; T0034/T0146: NOT from X-ALL.TXT -- disclosed as this port's own invention,
; since the state it covers (0 lives, nothing to flip back to in a 3-room
; slice) has no real equivalent in the original, which always has a title
; screen to fall back to. Removed in T0114 in favour of actually returning
; to the title; revived unchanged by T0146's decision to keep the memory
; the title's gathered stream cost instead of the title-screen return.
; Same box footprint as msg_deadwindow so it fully overdraws with no stray
; fragments.
msg_gameover
        fcb 16+6,128+10,64,9,18,6
        fcb 128+23,96,16+2
        fcc "GAME:OVER"
        fcb 128+21,104
        fcc "PRESS:SPACE"
        fcb 0

; T0236: msg_notgotallcoins/msg_gotallcoins (daisyrou1's ending text) are
; NOT here -- see target/msg_data_tape.asm's own header for why: this
; file is one of tools/dte's fixed 5 SOURCES, and DTE derives ONE shared
; codebook from the WHOLE corpus regardless of `if TAPE_ROOMS` (it has
; no idea the block is gated) -- adding text here, even gated, reshuffles
; that codebook's code ASSIGNMENTS (same 46-code count, different bit
; patterns) and changes the COMPRESSED BYTES of unrelated, already-
; shipped strings like msg_troll, breaking the -run build's byte
; identity. Confirmed directly: rebuilding TAPE_ROOMS=0 with the new
; text living here changed msg_troll's own compressed fcb bytes even
; though its SOURCE fcc text never changed.

; --------------------------------------------------------------------
; Item name text, X-ALL.TXT's own applemess/jugmess/loafmess -- real
; source strings, not authored. PURE TEXT (no leading XY opcode): the
; caller (show_inventory) sets msg_x/msg_y itself before each jsr
; prtmessage, since the same item's name is drawn at a different Y
; depending on which slot it currently occupies.
; --------------------------------------------------------------------
msg_name_apple
        fcc "@orig(X-ALL:1086/19)"
        fcb 0
msg_name_jug
        fcc "@orig(X-ALL:1087/19)"
        fcb 0
msg_name_loaf
        fcc "@orig(X-ALL:1088/19)"
        fcb 0
; Fallback for anything pickupable that doesn't have a specific name
; yet -- keeps show_inventory from ever showing a garbage pointer if
; the pickupable list grows before this table does.
; T0056: the railing had no name, so the inventory called it "AN
; OBJECT". X-ALL.TXT ~1105: `railingmess defb "@orig(X-ALL:1105/18)",mend`.
msg_name_railing
        fcc "@orig(X-ALL:1105/18)"
        fcb 0
; T0068: X-ALL.TXT has TWO names for this (`fullwhiskeymess`/
; `emptybottlemess`, ~1089/1099) toggled by `checkifdrunk` once Dizzy
; actually drinks it -- a mechanic this port doesn't implement yet, so
; it stays "full" the way a picked-up jug of water never empties either.
msg_name_whiskey
        fcc "@orig(X-ALL:1089/19)"
        fcb 0
; T0100: X-ALL.TXT `ropemess`: "@orig(X-ALL:1090/15)".
msg_name_rope
        fcc "@orig(X-ALL:1090/15)"
        fcb 0
; T0201: the rest of the carryables in BUILT rooms, every string
; X-ALL.TXT's own. Playtest: "both the Bone and the Key objects are
; listed in the inventory as AN OBJECT" -- they were two of THIRTEEN.
; extracted/actors.json records each actor's original message label, so
; there was no guessing: bonemess, keymess, mtbucketmess and the rest.
msg_name_bone
        fcc "@orig(X-ALL:1082/18)"
        fcb 0
msg_name_key
        fcc "@orig(X-ALL:1100/16)"
        fcb 0
msg_name_bean
        fcc "@orig(X-ALL:1081/19)"
        fcb 0
msg_name_bucket
        fcc "@orig(X-ALL:1101/15)"
        fcb 0
msg_name_cow
        fcc "@orig(X-ALL:1104/16)"
        fcb 0
msg_name_pickaxe
        fcc "@orig(X-ALL:1108/19)"
        fcb 0
msg_name_hole
        fcc "@orig(X-ALL:1084/18)"
        fcb 0
msg_name_rock
        fcc "@orig(X-ALL:1097/15)"
        fcb 0
msg_name_leaves
        fcc "@orig(X-ALL:1103/17)"
        fcb 0
msg_name_generic
        fcc "AN:OBJECT"
        fcb 0
msg_inv_exit
        fcc "EXIT"
        fcb 0

; check_drop_trigger: the dropped item's own proximity trigger.
;
; Dropping an item is not the point -- WHERE you drop it is. The original
; runs this straight after dropobject (`justexitinvent`, X-ALL.TXT ~5848,
; commented "CHECK DROPPING OBJECT BY TRIGGER"): the item carries a prox
; routine in its movingdata entry, and if Dizzy is standing in that box
; when it lands, the routine fires.
;
; Only the rope/gator pair is wired here -- it is the one whose room this
; build has. The others (bean, egg, rock, @orig(X-ALL:642/16), crowbar,
; bucket, keys) follow the same shape when their rooms arrive; see
; tools/room_items.py, which already lists all 20 item->room links.
;
; proxcrocrou sets the CROC's var1 to 255 (`tiecroc equ -16+var1` reaches
; back from the rope's record to the crocodile's), and crocodilerou then
; does `cp 255 / jr z,hestied`, which freezes it on frame 123 -- mouth
; shut, harmless. The rope itself is consumed.
check_drop_trigger
        lda drop_slot
        if TAPE_ROOMS
        lbeq cdt_done      ; T0234: the block below pushes cdt_done out
                            ; of an 8-bit branch's reach in this build
                            ; only -- the -run build keeps the short beq.
        else
        beq cdt_done
        endif
        if TAPE_ROOMS
        ; T0234: same drop_slot>100 split as drop_to_world (actors.asm)
        ; -- a tape-table item's frame still has to reach the FRAME_
        ; POTION/FRAME_CROWBAR checks below (both already anticipate a
        ; not-yet-built room, T0133's own comments -- rooms 45/88 now
        ; exist), just addressed against actor_init_tape instead.
        cmpa #100
        bls cdt_base
        suba #100
        deca
        ldb #ACTOR_STRIDE
        mul
        ldx #actor_init_tape
        leax d,x
        bra cdt_havex
cdt_base
        endif
        deca
        ldb #ACTOR_STRIDE
        mul
        ldx #actor_ram
        leax d,x                 ; X = the item that was just dropped
cdt_havex
        if TAPE_ROOMS
        jsr cdt_shop             ; T0223: room 22's shopkeeper box (any item); X preserved
        endif
        lda 4,x                  ; its frame
        cmpa #FRAME_KEY
        lbeq cdt_key              ; T0124
        cmpa #FRAME_POTION
        lbeq cdt_potion            ; T0133
        cmpa #FRAME_CROWBAR
        lbeq cdt_crowbar           ; T0133
        cmpa #FRAME_ROPE
        if TAPE_ROOMS
        lbne cdt_tape              ; T0223: egg (T0239), rocks (T0216), bean, bucket -- tape_code/tape_bean_code
        else
        bne cdt_done
        endif
        lda cur_room
        cmpa #53
        bne cdt_done
        lda #CROC_PROX_X
        sta ah_bx
        lda #CROC_PROX_Y
        sta ah_by
        lda #CROC_PROX_W
        sta ah_bw
        lda #CROC_PROX_H
        sta ah_bh
        pshs x
        jsr aabb_hit
        puls x
        tsta
        beq cdt_done
        ; tie it: the crocodile's v1 = 255
        ldy #actor_ram
        lda #ACTOR_COUNT
        sta cdt_n
cdt_find
        lda 1,y
        cmpa #ROU_CROCODILE
        beq cdt_tie
        leay ACTOR_STRIDE,y
        dec cdt_n
        bne cdt_find
        bra cdt_done
cdt_tie
        lda #255
        sta 5,y                  ; var1 = tied
        sta ,x                   ; the rope is consumed
        jsr msg_begin
        ldx #msg_croctied
        jsr msg_box_done       ; T0221 (was 9 bytes inline)
cdt_done
        rts

cdt_n   fcb 0
        if TAPE_ROOMS
cdk_mx  fcb 0
cdk_my  fcb 0
cdk_liftroom fcb 0
        endif
msg_active fcb 0   ; T0154: nonzero while a message box blocks for a key

; T0133: proxsleep (X-ALL.TXT ~2741) -- fires only when the
; potion item (FRAME_POTION, sleepingpotionhere, room 45 -- not built) is
; dropped in room 54's DRAGON_SLEEP_* box. Was wrongly wired as mere
; proximity in update_dragon; moved here to match justexitinvent ->
; checkproximity. proxsleeprou consumes the potion, latches dragon_asleep
; (update_dragon's own retraction animation then takes over, unchanged),
; and shows dragonasleepmess. The box-hit-plus-effect part is shared with
; debug_prox_keys (below) via fire_dragonsleep, since the debug key needs
; to fire the same effect with no item to consume.
cdt_potion
        lda cur_room
        cmpa #54
        lbne cdt_done
        lda #DRAGON_SLEEP_X
        sta ah_bx
        lda #DRAGON_SLEEP_Y
        sta ah_by
        lda #DRAGON_SLEEP_W
        sta ah_bw
        lda #DRAGON_SLEEP_H
        sta ah_bh
        pshs x
        jsr aabb_hit
        puls x
        tsta
        lbeq cdt_done
        lda #255
        sta ,x                    ; the potion is consumed
        jsr fire_dragonsleep
        rts

; T0133: proxcrowbar (X-ALL.TXT ~3443) -- fires only when the CROWBAR
; (FRAME_CROWBAR, crowbarhere, room 88 -- not built) is dropped in room
; 55's WELLLID_PROX_* box. Was wrongly wired as mere proximity in
; update_welllid (now removed); moved here to match justexitinvent ->
; checkproximity. proxcrowbarrou consumes the crowbar, hides the lid
; actor (room=255, same one-shot-by-hiding trick update_welllid used),
; and shows usecrowbarmess (msg_crowbar). Shares fire_welllid with
; debug_prox_keys the same way cdt_potion shares fire_dragonsleep.
cdt_crowbar
        lda cur_room
        cmpa #55
        lbne cdt_done
        lda #WELLLID_PROX_X
        sta ah_bx
        lda #WELLLID_PROX_Y
        sta ah_by
        lda #WELLLID_PROX_W
        sta ah_bw
        lda #WELLLID_PROX_H
        sta ah_bh
        pshs x
        jsr aabb_hit
        puls x
        tsta
        lbeq cdt_done
        lda #255
        sta ,x                     ; the crowbar is consumed
        jsr fire_welllid
        rts

; fire_dragonsleep / fire_welllid: the box-already-hit part of proxsleep/
; proxcrowbar -- state change + message only, no item involved. Called
; by cdt_potion/cdt_crowbar (after they've confirmed the hit AND
; consumed the item) and by debug_prox_keys (after ITS OWN aabb_hit,
; with no item to consume at all -- rooms 45/88 don't exist yet).
fire_dragonsleep
        lda #1
        sta dragon_asleep
        jsr msg_begin
        ldx #msg_dragonasleep
        jsr msg_box_done       ; T0221 (was 9 bytes inline)
        rts

; Only shows the message/latches the buffers if the lid was actually
; found still present (room==cur_room) -- if it's already hidden this
; is a no-op, same one-shot-by-hiding guard the dragon gets from
; dragon_asleep, needed here for debug_prox_keys' dpk_well (holding the
; key can't re-fire the message every frame once the lid is gone).
fire_welllid
        ldy #actor_ram
        lda #ACTOR_COUNT
        sta cdt_n
cdc_find
        lda ,y
        cmpa cur_room
        bne cdc_next
        lda 1,y
        cmpa #ROU_CROWBAR
        beq cdc_found
cdc_next
        leay ACTOR_STRIDE,y
        dec cdt_n
        bne cdc_find
        rts                         ; not found: already hidden, no-op
cdc_found
        lda #255
        sta ,y                     ; hide the lid
        jsr msg_begin
        ldx #msg_crowbar
        jsr msg_box_done       ; T0221 (was 9 bytes inline)
        rts

; T0133: debug_prox_keys -- see room36.asm's DEBUG_PROX_KEYS flag for
; why this exists. Holding 'D' (matrix row0/col4) in room 54's box fires
; fire_dragonsleep exactly as dropping the potion would (minus consuming
; an item that doesn't exist in this build); holding 'F' (matrix
; row0/col6) does the same for fire_welllid in room 55. Gated on
; cur_room first (cheap, and matches how every other per-room trigger
; here is gated) before touching the PIA, and on dragon_asleep/the lid's
; own one-shot hide so holding the key can't re-fire after the effect
; has already latched.
debug_prox_keys
        lda cur_room
        cmpa #54
        beq dpk_dragon
        lda cur_room
        cmpa #55
        beq dpk_well
        rts

dpk_dragon
        tst dragon_asleep
        bne dpk_done               ; already latched: don't re-fire
        lda #%11101111              ; column 4 -- row0/col4 = 'D' (matrix
                                     ; table: row0 @ A B C D E F G at
                                     ; columns 0-7, so D is column 4, NOT
                                     ; 3 -- same column as the DOWN key,
                                     ; different row, no collision)
        sta $ff02
        lda $ff00
        anda #%00000001              ; row 0 = 'D'
        bne dpk_done                 ; not pressed (inverted: 0=pressed)
        lda #DRAGON_SLEEP_X
        sta ah_bx
        lda #DRAGON_SLEEP_Y
        sta ah_by
        lda #DRAGON_SLEEP_W
        sta ah_bw
        lda #DRAGON_SLEEP_H
        jsr aabb_test          ; T0221 (was 7 bytes inline)
        beq dpk_done
        jsr fire_dragonsleep
dpk_done
        rts

dpk_well
        lda #%10111111              ; column 6 (matrix col6, same as right)
        sta $ff02
        lda $ff00
        anda #%00000001              ; row 0 = 'F'
        bne dpk_done                 ; not pressed
        lda #WELLLID_PROX_X
        sta ah_bx
        lda #WELLLID_PROX_Y
        sta ah_by
        lda #WELLLID_PROX_W
        sta ah_bw
        lda #WELLLID_PROX_H
        jsr aabb_test          ; T0221 (was 7 bytes inline)
        beq dpk_done
        jsr fire_welllid
        bra dpk_done

; T0239: proxkey1-4rou (X-ALL.TXT ~2906-2928). The original dispatches
; purely by WHERE DIZZY IS STANDING when he drops the key (each slot's
; own -16/-32 table-relative machine/lift, `turnmachineon equ -16+var1`/
; `turnlifton equ -32+var1`) -- NOT by which physical key it is (all
; four `proxkeyNrou` bodies are `jr proxkey1rou`, byte-identical code).
; T0124's own cdt_key only ever tested slot 1's box -- keys 2-4 either
; did nothing (dropped in their own correct slot) or wrongly fired lift
; 71 (dropped in slot 1's box instead): a real puzzle-chain bug, caught
; by the coordinator's own review of T0238, not invented here. Keys 2
; and 3 are ALREADY pickupable in BASE rooms 24/60 (T0124's own actor
; table), so this is a real bug in the -run build too -- reported, not
; silently fixed there: the `else` branch below is T0124's own code,
; byte-for-byte, so room36.bin stays identical to HEAD pending the
; coordinator's approval. `cdt_key_tab` is one entry per slot (box
; pixel x,y, that slot's own machine pixel x,y, its own lift room),
; each x scaled from X-ALL.TXT's raw table the same way every other
; placement in this port is (`(raw-32)*4`, y unscaled -- confirmed
; exact against every one of this port's own already-shipped x values,
; including the resident machine/lift/key records T0124 already built,
; before use here -- factory's own "check the pattern quantitatively"
; recipe, not assumed).
FRAME_KEY equ 13
        if TAPE_ROOMS
cdt_key_tab
        fcb 76,120,72,116,71      ; slot 1 (key 1, room 85) -> lift 71
        fcb 164,120,160,116,40   ; slot 2 (key 2, room 24) -> lift 40
        fcb 84,160,80,156,88     ; slot 3 (key 3, room 60) -> lift 88
        fcb 156,160,152,156,56   ; slot 4 (key 4, room 48) -> lift 56 (its own)
CDT_KEY_SLOTS equ 4
cdt_key
        lda cur_room
        cmpa #56
        lbne cdt_done
        ldu #cdt_key_tab
        ldb #CDT_KEY_SLOTS
cdk_boxlp
        lda ,u
        sta ah_bx
        lda 1,u
        sta ah_by
        lda #16
        sta ah_bw
        sta ah_bh
        pshs x
        jsr aabb_hit
        puls x
        tsta
        bne cdk_found
        leau 5,u
        decb
        bne cdk_boxlp
        lbra cdt_done             ; not standing in any slot's box
cdk_found
        lda #255
        sta ,x                    ; the key stays in the machine
        lda 2,u
        sta cdk_mx
        lda 3,u
        sta cdk_my
        lda 4,u
        sta cdk_liftroom
        ldy #actor_ram
        lda #ACTOR_COUNT
        jsr cdk_scan
        ldy #actor_init_tape
        lda #ACTOR_COUNT_tape
        jsr cdk_scan
        jsr msg_begin
        ldx #msg_keyinmachine
        jsr msg_box_done
        rts
cdk_scan
        sta cdt_n
cdk_lp
        lda 1,y
        cmpa #ROU_MACHINES
        bne cdk_notmach
        lda 2,y
        cmpa cdk_mx
        bne cdk_next
        lda 3,y
        cmpa cdk_my
        bne cdk_next
        lda 5,y
        ora #1
        sta 5,y                  ; turnmachineon
        bra cdk_next
cdk_notmach
        cmpa #ROU_LIFT
        bne cdk_next
        lda ,y
        cmpa cdk_liftroom
        bne cdk_next
        lda 5,y
        ora #1
        sta 5,y                  ; turnlifton
cdk_next
        leay ACTOR_STRIDE,y
        dec cdt_n
        bne cdk_lp
        rts
        else
cdt_key
        lda cur_room
        cmpa #56
        lbne cdt_done
        lda #76
        sta ah_bx
        lda #120
        sta ah_by
        lda #16
        sta ah_bw
        sta ah_bh
        pshs x
        jsr aabb_hit
        puls x
        tsta
        lbeq cdt_done
        lda #255
        sta ,x                   ; the key stays in the machine
        ldy #actor_ram
        lda #ACTOR_COUNT
        sta cdt_n
cdk_lp
        lda 1,y
        cmpa #ROU_MACHINES
        bne cdk_notmach
        lda 2,y
        cmpa #72
        bne cdk_next
        lda 3,y
        cmpa #116
        bne cdk_next
        lda 5,y
        ora #1
        sta 5,y                  ; turnmachineon
        bra cdk_next
cdk_notmach
        cmpa #ROU_LIFT
        bne cdk_next
        lda ,y
        cmpa #71
        bne cdk_next
        lda 5,y
        ora #1
        sta 5,y                  ; turnlifton
cdk_next
        leay ACTOR_STRIDE,y
        dec cdt_n
        bne cdk_lp
        jsr msg_begin
        ldx #msg_keyinmachine
        jsr msg_box_done       ; T0221 (was 9 bytes inline)
        rts
        endif

; item_name_msg: A = carried item's frame id -> D = pointer to its name
; message (text only, see above).
item_name_msg
; T0201: a TABLE, not a compare chain. It was seven `cmpa/bne/ldd/rts`
; blocks, so adding a name cost five instructions each -- which is why
; thirteen carryables in built rooms were still falling through to
; "AN OBJECT" ("both the Bone and the Key are listed as AN OBJECT").
; (frame:1, pointer:2) entries, a frame of 0 ends it.
        ldx #item_name_tab
inm_scan
        ldb ,x                   ; frame id, 0 = end of table
        beq inm_generic
        pshs a
        cmpb ,s+
        beq inm_found
        leax 3,x
        bra inm_scan
inm_found
        ldd 1,x
        rts
inm_generic
        ldd #msg_name_generic
        rts

item_name_tab
        fcb FRAME_APPLE
        fdb msg_name_apple
        fcb FRAME_JUG
        fdb msg_name_jug
        fcb FRAME_LOAF
        fdb msg_name_loaf
        fcb FRAME_RAILING
        fdb msg_name_railing
        fcb FRAME_WHISKEY
        fdb msg_name_whiskey
        fcb FRAME_ROPE
        fdb msg_name_rope
        fcb FRAME_BONE
        fdb msg_name_bone
        fcb FRAME_KEY
        fdb msg_name_key
        fcb FRAME_BEAN
        fdb msg_name_bean
        fcb FRAME_BUCKET
        fdb msg_name_bucket
        fcb FRAME_COW
        fdb msg_name_cow
        fcb FRAME_PICKAXE
        fdb msg_name_pickaxe
        fcb FRAME_HOLE
        fdb msg_name_hole
        fcb FRAME_ROCK1
        fdb msg_name_rock
        fcb FRAME_ROCK2
        fdb msg_name_rock
        fcb FRAME_ROCK3
        fdb msg_name_rock
        fcb FRAME_LEAVES
        fdb msg_name_leaves
        fcb 0                     ; end
