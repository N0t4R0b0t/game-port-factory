; Room 36 (THE CASTLE'S DUNGEON) static scene, T0015 slice.
; PMODE4 (256x192, 2-color) set up from scratch (see pm4test.asm/NOTES.md),
; then blits every scenery placement from room36_data.asm.
;
; Blit routine handles exactly two horizontal sub-byte alignments, not an
; arbitrary shift: pixel_x is always a multiple of 4 (confirmed transform,
; NOTES.md "Correction #2"), so pixel_x mod 8 is only ever 0 or 4.

BUFA    equ $4000
BUFB    equ $6000       ; buffer B: $4000 + $2000, same F5 bit as buffer A plus F4
                         ; set (Inman & Inman appendix E, "screen offsets": offset
                         ; $2000 is set via $FFCF, cleared via $FFCE -- a single
                         ; strobe flips which 6K buffer the VDG displays).
FBWIDTH equ 32          ; bytes per screen row (256px / 8)
; T0125: X-ALL.TXT's flipscreenrou swaps screentable entries 6*8..183, so
; the upside-down world mirrors exactly rows 48..183: row r <-> 231-r.
FLIP_SUM  equ 48+183
FLIP_YEND equ 184       ; first row past the flipped window

; Horizontal clamp: keep Dizzy's fixed-24px-wide sprite fully on the
; 256px screen (all 39 frames are 24px wide, only height varies --
; NOTES.md "Recover: Dizzy's own movement/physics/collision/animation").
; T0050, comparing against the original: Dizzy's own `x` in X-ALL.TXT is
; NOT in pixels -- it is in FOUR-PIXEL units. PRTDIZZY.PDS proves it
; (`ld a,(dizx) / srl c` makes x/2 the screen BYTE column, so one unit is
; 8/2 = 4 pixels, with the low bit selecting the 4px sub-byte shift this
; port's blit already implements). The routine's own header comment says
; "e=x (0=left 255=right)", which is simply stale -- believing it is what
; put several derived constants here in pixel units when the source's
; numbers were units.
;
; Everything falls out of that scale, and it all cross-checks:
;   movement    x +/- 1 per tick          -> WALK_STEP = 4 px  (already!)
;   left edge   `cp 1  / jp z,goneleft`   -> transition at 4 px
;   right edge  `cp 57 / jp z,goneright`  -> transition at 228 px
;   goneright   `ld a,2  / ld (x),a`      -> arrive at 8 px
;   goneleft    `ld a,56 / ld (x),a`      -> arrive at 224 px
; so the walkable span is x=2..56 in units == 8..224 px, which is exactly
; a 24px-wide sprite kept fully on a 256px screen (224+24 = 248).
;
; Note what this says about WALK_STEP: 4px/tick IS the original's real
; speed, not the "modern feel" deviation NOTES.md has claimed since
; T0019. The "source-faithful" 1px/tick that felt wrong was 4x too slow,
; because it read the source's 1 as 1 pixel instead of 1 unit.
; T0061: mainloop period, in 60Hz video fields.
;
; The original has TWO rates, and this port had been running everything
; at the faster one -- which is why a playtest reported "the margin of
; error for the ledge is tiny, it wasn't this hard in the original":
;
;   * DIZZY moves at 12.5Hz. `updatedizzy` (X-ALL.TXT ~6339) is called
;     from the raw 50Hz interrupt but opens with an `eggcount` divider of
;     4, so his position, physics and animation advance 12.5 times a
;     second. One step is 1 unit = 4px (`ld a,(x) / sub (left) / add
;     (right)`), so he walks at exactly 50 px/sec.
;   * THE WORLD moves at 16.7Hz. `maingamelp` (~1344) waits for 3 ticks
;     of the same 50Hz clock -- its own comment reads ";;;main loop cycle
;     time 1/50 secs unit" -- and that paces domoving (rat, troll,
;     gator), the flames, the water and the pickups.
;
; At FRAME_FIELDS=3 this port ran BOTH at 20Hz, so Dizzy walked at
; 80 px/sec: **1.6x the original**. Same pixels, same jump arc, 60% less
; time to react to any of it. Every "this is harder than the original"
; report traces back here, and no amount of collision tuning would have
; fixed it, because the geometry was right all along.
;
; 4 fields is 15Hz: Dizzy +20% (60 px/sec), the world -10%. That is the
; closest a whole number of NTSC fields gets with ONE rate, and the
; error is now smaller than the frame-rate variation the port had before
; T0051. Exactness needs two clocks -- Dizzy on 4.8 fields, the world on
; 3.6 -- which is real work and a real risk of uneven motion (a skipped
; step every 6th pass reads as a hitch), so it is deliberately not done
; here; see NOTES.md T0061 for the arithmetic if it ever matters.
;
; It also removes the pacing variation entirely, which was its own
; playtest complaint ("everything speeds up when the fire goes out"):
; the heaviest scene costs ~36ms of a 66.7ms budget, against 50ms
; before, so every room now holds 15.0 instead of drifting 20.0/19.0.
FRAME_FIELDS equ 4
; T0064: PROFILE=1 makes each mainloop/redraw phase stamp its id into
; `prof_slot`. harness/profile.lua taps writes to that address and
; timestamps them, so a run yields the exact microsecond cost of every
; phase -- no ablation, no arithmetic on differences of noisy totals.
; Costs 7 cycles a marker and is compiled out entirely when 0.
        ifndef PROFILE
PROFILE      equ 0
        endif

; T0133: DEBUG_PROX_KEYS=1 (default) enables the dragon-sleep/well-lid
; debug keys: holding 'D' (matrix row0/col4, unused elsewhere) in room
; 54's DRAGON_SLEEP_* box fires the sleeping-potion drop-trigger without
; the potion; holding 'F' (matrix row0/col6) in room 55's
; WELLLID_PROX_* box fires the crowbar drop-trigger without the crowbar.
; Gated two ways: this build flag (so a release build can drop it with
; `-DDEBUG_PROX_KEYS=0`), AND the fact that it only ever fires while
; standing in one of two ~tile-sized boxes -- nowhere a normal
; playthrough's own key input would pass through unintentionally. Exists
; because rooms 45 (potion) and 88 (crowbar) aren't built yet, so the
; passages these two triggers block would otherwise be untestable. See
; check_drop_trigger's cdt_potion/cdt_crowbar (gameplay.asm) --
; debug_prox_keys there calls the exact same effect subroutine, just
; without the item-consumption step.
        ifndef DEBUG_PROX_KEYS
DEBUG_PROX_KEYS equ 1
        endif

; Profiling switch: build with `lwasm -DPACING=0` to disable the pacing
; wait and let the loop free-run, which is how NOTES.md's per-phase frame
; costs were measured (ablate a phase by replacing its `jsr` with `nop`).
        ifndef PACING
PACING       equ 1
        endif

; T0085 -- STAGE_LZ: are the two staged $8000 blocks stored PACKED?
;
; Staging is hard-capped at 12288 bytes (the two framebuffers are the
; only windows CLOADM can write that are also free at boot) and the raw
; image is 11756, so nothing more fits. Packed it is ~7600, which puts
; the cap back where it belongs. 0 = raw, and it must still build that
; way: the raw pass is what GENERATES the packed one. See
; tools/stage_pack.sh -- do not build this file with -DSTAGE_LZ=1 by
; hand, the blobs and staged_syms.asm come from pass 1 and go stale.
        ifndef STAGE_LZ
STAGE_LZ     equ 0
        endif

; T0230: TAPE_ROOMS -- do rooms 74/75 exist in this build at all?
;
; Proving step for a tape-only memory region: rooms delivered directly
; to their FINAL $8000+ address by target/tape_stage1.asm's existing
; addr>=$8000 segment path, living in the free span [IMAGE_END,
; CODE_DEST) -- no framebuffer staging, no LZ pack, no title-hole
; gather (see the TAPE_ROOMS block further down, right after the T0148
; staged-code block resolves CODE_DEST).
;
; Default 0: room36.bin (the -run/CLOADM build, tools/stage_pack.sh)
; never defines this, so rooms 74/75 do not exist in that build at all
; -- not just unreachable, ABSENT from room_desc_table and the source
; image, so it stays byte-for-byte what it was before this task.
; tools/tape_pack.sh builds a SECOND, separate image
; (target/room36_tape.bin) with -DTAPE_ROOMS=1, which is the only build
; that ever assembles the block below.
        ifndef TAPE_ROOMS
TAPE_ROOMS   equ 0
        endif
; T0241: FLOPPY=1 -- the RS-DOS disk build (target/dizzy.dsk, tools/floppy_pack.sh) on top of
; TAPE_ROOMS=1: same content as the tape build, loaded by target/floppy_stage1.asm from DIZZY.DAT,
; plus overlays read from DIZZY.OVL on demand (target/floppy_code.asm). Everything FLOPPY-only is
; gated `if FLOPPY`; with FLOPPY=0 (the -run and tape builds) nothing here assembles.
        ifndef FLOPPY
FLOPPY       equ 0
        endif
        if FLOPPY
        ifeq TAPE_ROOMS
        error "FLOPPY=1 requires TAPE_ROOMS=1 (the floppy build is the tape build plus a disk)"
        endif
        endif

; START_ROOM / START_X / START_Y -- drop Dizzy straight into a room at
; boot, for TESTING. `./play.sh 51` builds with -DSTART_ROOM=51 rather
; than making you walk there every time.
;
; The defaults for room 36 are the real opening beat and must not
; change: x=184 puts Dizzy inside the troll's proximity box, so a new
; game opens with the troll shoving him west, which is what the ZX
; capture shows. Any OTHER room gets a neutral drop at x=128,y=80 --
; below TOP_TRANSITION_Y (66), so settling does not trigger an
; up-transition, and airborne so real collision finds the floor instead
; of a guessed height.
        ifndef START_ROOM
START_ROOM   equ 36
        endif

; TITLE_MIX3 -- title tune as the original's full 3-voice AY arrangement
; (target/title_mix3.asm) instead of the single-voice melody. 1 = SHIPPING
; (T0113, user's call after listening). `TITLE_MIX3=0 tools/stage_pack.sh`
; builds the old single-voice title (pt_step loop over tune0_notes).
        ifndef HCLIP
HCLIP        equ 1      ; T0211: clip blit horizontally. ON by default since
                          ; T0219 freed the bytes by deleting inv_has/inv_remove.
                          ; Without it a sprite overrunning column 31 wrote its
                          ; tail into the NEXT ROW's left edge (the framebuffer is
                          ; one flat 32-byte-per-row span), which showed as stray
                          ; pixels down the left of rooms 22/50/51/54/57/59/67/68.
                          ; Set 0 only to measure against the old behaviour.
        endif
        ifndef INF_LIVES
INF_LIVES    equ 0      ; playtest aid: 1 = a death never costs a life (the
                          ; death box/tune and respawn still happen). Set by
                          ; ./play.sh --inf-lives; never on in a shipped build.
        endif
        ifndef DEBUG_XY
DEBUG_XY     equ 0      ; T0191: 1 = show live room/x/y instead of the room
                         ; name in the banner. Build-time, testing only.
        endif
        ifndef TITLE_MIX3
TITLE_MIX3   equ 1
        endif

; START_ITEM1..3 -- seed Dizzy's inventory at boot, for TESTING.
; `./play.sh 53 rope` builds with -DSTART_ITEM1=14. Values are FRAME
; numbers (the same ids gameplay.asm's FRAME_* equs use); 0 = no item.
; Three because inv_cap is 3 without the bag.
        ifndef START_ITEM1
START_ITEM1  equ 0
        endif
        ifndef START_ITEM2
START_ITEM2  equ 0
        endif
        ifndef START_ITEM3
START_ITEM3  equ 0
        endif
; T0225b (L4): seed_inventory (81 B incl. its call) is a test aid. The TAPE build drops it
; unless some START_ITEMn is set; the -run build always keeps it (room36.bin stays identical).
        ifeq TAPE_ROOMS
SEED_INV     equ 1
        else
        ifeq START_ITEM1+START_ITEM2+START_ITEM3
SEED_INV     equ 0
        else
SEED_INV     equ 1
        endif
        endif
        ifndef START_X
        if START_ROOM-36
START_X      equ 128
        else
START_X      equ 184
        endif
        endif
        ifndef START_Y
        if START_ROOM-36
START_Y      equ 80
        else
START_Y      equ 168
        endif
        endif

DIZZY_MINX   equ 8      ; leftmost standing x (source x=2); stepping left
                         ; from here is the goneleft transition
DIZZY_MAXX   equ 224    ; rightmost standing x (source x=56); stepping
                         ; right from here is the goneright transition.
                         ; Was 232 ("256-24"), which let Dizzy stand two
                         ; 4px steps further right than the original can.

; Physics (NOTES.md same section, recovered from X-ALL.TXT
; bettercheckkeys/checkbottomside): dizzy_y tracks Dizzy's FEET (bottom
; edge), matching the original -- each frame is drawn from
; dizzy_y-height up to dizzy_y, not top-anchored, so shorter frames
; (tumbling/crouching) don't make him float upward. FLOOR_Y is room
; 36's flat floor -- this slice deliberately doesn't implement general
; collision yet (see NOTES.md; that's real, separate, later work), so
; there's exactly one solid Y for the whole room.
GRAVITY      equ 1      ; dy added per frame while airborne
JUMP_DY      equ -8     ; initial upward velocity on jump
FALL_CAP     equ 7      ; terminal fall speed (dy magnitude clamp)

; CORRECTED, T0050 -- read the rest of this comment as history, not as
; current reasoning. X-ALL.TXT's checkkeys does set `left`/`right` to a
; 0/1 flag added to `x` once per tick, but `x` is in FOUR-PIXEL units
; (PRTDIZZY.PDS makes x/2 the screen byte column; see DIZZY_MAXX's own
; comment above for the full derivation and its cross-checks). So the
; original's real step is 1 unit = **4 pixels** per tick, and WALK_STEP=4
; is the FAITHFUL value -- not the "modern feel" deviation the rest of
; this comment agonises over. The 1px/tick that felt wrong when tried was
; simply four times too slow. Everything below is kept because the
; playtest history is still useful; the conclusion it reaches happens to
; be right for the wrong reason.
;
; X-ALL.TXT's checkkeys sets `left`/`right` to a plain 0/1 flag, and that
; flag is added/subtracted from `x` directly, once per (its own, distinct
; ~12.5Hz) update tick -- the ORIGINAL's real horizontal step is exactly
; 1 pixel/tick, not some larger value needing a *4 scale-up (the room-
; placement (x-32)*4 transform elsewhere in this port does NOT apply to
; Dizzy's own coordinates -- confirmed separately, see NOTES.md). This
; port had been moving 4px/pass here, which combined with vsync pacing
; made walking look like big visible hops rather than a glide -- reported
; back as "feels slow" (meaning chunky/unresponsive, not literally slow:
; measured, the 4px version already covered ground 4-5x faster than the
; real original).
;
; Tried WALK_STEP=1 (exact source match, ~17px/sec at this port's pass
; rate) -- reported back as "slow stutters", worse, not better: 1px
; steps at ~17Hz apparently read as sparse/discrete rather than a glide,
; even though that IS what the real 1989 hardware produces. Strict
; fidelity here doesn't feel good on a modern screen. Reverted to 4 (the
; original pre-fidelity value) as a deliberate "modern feel" choice, not
; an oversight -- explicitly picked by the user over 2x and over redraw-
; rate smoothing, with the caveat that 4 was also the value already
; reported as chunky before this whole investigation started. If it
; still isn't right, the next thing to question isn't this number again
; -- it's the ~17Hz redraw cadence itself (see the "redraw more often"
; option in NOTES.md's pacing discussion).
WALK_STEP    equ 4

; STEP_UP: how far the floor search starts ABOVE Dizzy's feet each frame,
; X-ALL.TXT checkbottomside's `ld a,(y) / sub 4`. Steps up to roughly
; this tall are climbed by walking into them. Paired with check_wall's
; lowest probe (y-10): between them they decide what is walkable vs what
; needs a jump. See the main loop's vertical block.
STEP_UP      equ 4

; T0035: vertical room transitions -- X-ALL.TXT's checktopside/
; checkbottomside, which this port's ml_uplp/ml_downlp already mirror in
; structure (same per-row scan-until-blocked shape as T0031's step-climb).
; The source triggers goneup once y (top-anchored) drops below 66 while
; still rising and unblocked, and gonedown once y passes 182 while still
; falling and unblocked -- i.e. it does NOT wait to reach the literal top/
; bottom of the screen, only "comfortably past where this room's own
; wall art is". TOP_TRANSITION_Y/BOT_TRANSITION_Y are this port's feet-
; anchored equivalents, sized generously (not derived from the source's
; raw values, which used a different y-anchor and a fixed eggheight this
; port already avoids reusing -- see REACH_MARGIN's own comment) so the
; transition fires only once Dizzy has visibly climbed clear of room 36's
; wall row / fallen well past any of room 52's own stair geometry.
;
; Room 36's own collision mask (room36_data.asm, verbatim from
; rooms.json) has exactly one ceiling gap reachable from its walkable
; floor: x~196-232, next to the rope decoration (frame 130) -- confirmed
; by checking column coverage, not guessed. The far left/right screen
; edges (x<8, x>247) are ALSO open in both room 36 and room 52's own
; data, but are not reachable by walking (room 36 has no floor there
; either), so nothing needs to special-case them: check_ceiling/
; check_ground simply won't ever be probed from a position Dizzy can
; actually stand in. The mechanic below is fully geometry-driven, same
; principle as T0031 -- no hardcoded x range.
; T0044, real playtest: "when you jump up over the gap over the top of
; the rat patrol area dizzy should go to the above room right away, he
; shouldn't be able to walk on that area on top of the screen".
;
; TOP_TRANSITION_Y was 40, and 40 IS SIMPLY UNREACHABLE from the rat
; corridor: its floor is the slab top at y=80, and a jump rises 32px
; (JUMP_DY=-8 with GRAVITY=1 -- measured, not estimated), so the apex is
; y=48 at best. The transition therefore never fired at all; instead
; Dizzy apexed level with the y=48 wall row, drifted sideways out of the
; x=192-231 ceiling gap, and LANDED ON TOP OF THE WALL, where he could
; then walk around above the room. Every symptom the playtest describes.
;
; 66 is the source's own number (X-ALL.TXT `checktopside`: `ld a,(y) /
; dec a / cp 66 / jp c,goneup`), and it works here unchanged because
; this port's dizzy_y is feet-anchored exactly like the source's own `y`
; (NOTES.md T0011). The earlier "sized generously, not derived from the
; source's raw values" reasoning above was the mistake -- the raw value
; was right all along, and picking a rounder-looking number quietly
; broke the mechanic.
;
; Why it now behaves: standing on the slab at y=80, rising is blocked by
; check_ceiling at y=73 everywhere the y=48 wall is overhead (head hits
; its underside first), so only the real gap lets him past -- and there
; he reaches 65 < 66 and transitions immediately, before he can ever get
; high enough to stand on the wall.
TOP_TRANSITION_Y equ 68    ; feet y. X-ALL.TXT checktopside `dec a / cp 66 / jp c,goneup` on the ORIGINAL's y: leaves at y<=66 = port y<=67
                           ; (port feet are the original's +1, T0232; was 66, which needed 2px more than the original)
BOT_TRANSITION_Y equ 182   ; feet y. T0137: X-ALL.TXT checkbottomside's `inc a / cp 182 /
                           ; jp nc,gonedown` leaves at y=181 and arrives at 181-114=67;
                           ; port feet sit 1px below the original's, so 182 -> 68. 188
                           ; arrived 6px low, under room 71's lift top, and broke the
                           ; original's 71/87 loop.

; --- T0080: the PLAY WINDOW, straight out of X-ALL.TXT ----------------
;   windowtop     defb 6*8      ;0    alter these directly
;   windowbottom  defb 192-8    ;192  to change window
;
; The original does not draw a room into the whole screen -- it clips
; every sprite it plots (scenery, actors, Dizzy) to that window, in the
; routine at ~3995: sprites starting above `windowtop` have their first
; rows skipped and their source pointer walked forward to match
; (`movestartdown`), sprites running past `windowbottom` have their row
; count truncated.
;
; This port had no window at all, and it showed: a playtest screenshot
; of room 36 next to the Spectrum's own put it plainly -- "the play area
; is too tall compare to the zxspectrum". Room 36's art starts at y=48
; because 48 IS the original's window top; drawing it into a play area
; that began at y=24 left a 24px band of empty black above the room's
; own ceiling, and rooms whose art starts higher still (51 and 53 begin
; at y=32) spilled art the original would simply have cut off.
;
; Checked across all 52 rooms that have content, not just the built
; nine: topmost placement y is 48 in 12 rooms, 40 in 8, 32 in 4, and
; the global minimum is 22 -- i.e. the data really does run above the
; window, exactly as something that expects to be clipped would.
; T0092 scratch, all above the unpacked room image (which ends by $b83c)
; and below $FF00 where the SAM/PIA registers live.
; T0107: IMAGE_END/TITLE_LZ_BUF/TITLE_RAW_BUF/BANNER_BUF are defined
; AFTER the staged-block if/else/endif further down (search "T0107
; scratch buffers"), NOT here. R9800_DEST-based formulas mean something
; DIFFERENT per branch: r9800_staged_end brackets a PACKED BLOB in the
; STAGE_LZ branch (its packed length, e.g. 6099) but the RAW CONTENT in
; the else branch (its true length, e.g. 9307). A single top-level
; formula here used the packed one in the packed build, so IMAGE_END
; came out $BC10 instead of the real $C898 -- 2696 bytes short, landing
; INSIDE the staged room image instead of after it, and show_title's own
; scratch writes silently clobbered the tail of Dizzy's animation
; frames every boot. Found by lzverify, not by play -- NOTES.md T0107
; has the full postmortem, including why a per-branch definition (like
; R9800_DEST already has) is the only correct shape.
BANNER_BYTES  equ 48*32
; T0148: same reasoning as BANNER_BYTES above -- a fixed reservation, not a
; derived length, because CODE_DEST (below, once BANNER_BUF exists) has to
; be known BEFORE the staged code block it bounds can be phased. Defined
; here, outside the STAGE_LZ if/else, so both branches see the same value.
        if TAPE_ROOMS
TAPE_CODE_SLACK_GIVEN equ 40   ; T0226: block D's 91 B budget slack, handed to the tape-only
                                ; region below it (CODE_DEST rises by this much) so the room-41
                                ; rock's record+sprite fit. The tape build's raw block D is
                                ; 3237 B; the assemble-time guard on code_staged_end still holds.
CODE_BUDGET   equ 3328-TAPE_CODE_SLACK_GIVEN
        ; T0227: the black hole (checkholdinghole X:2520) is implemented and verified, but costs 125 B
        ; (msg_holdinghole 65 + tape_hole_check 60) that the T0227 budget did not have. 1 = build it in.
TAPE_HOLE     equ 1
        else
CODE_BUDGET   equ 3328
        endif
        ; T0161 (CODE_BUDGET): update_dragon+dragon_flames (308 raw) plus
                            ; update_crocodile+update_portcullis (~406 raw
                            ; combined) -- see croc_portcullis_code.asm.
                            ; T0162: plus update_rat+rat_newdir+
                            ; find_loaf_and_eat+update_troll+the hazard
                            ; trio (rat_troll_hazard_code.asm) and
                            ; update_armorog+update_lifts+update_door+
                            ; update_dagger (armorog_lifts_dagger_code.asm)
                            ; -- measured raw total 2018 bytes, rounded up.
                            ; Guarded below by code_staged_end-code_staged_start.

WINDOW_TOP    equ 48       ; X-ALL.TXT windowtop    = 6*8
WINDOW_BOTTOM equ 184      ; X-ALL.TXT windowbottom = 192-8

; --- collision (T0022) -------------------------------------------------
; Real mask-based collision, replacing the single hardcoded FLOOR_Y this
; slice used while the renderer was being debugged. room_cmask (emitted
; by tools/roompack, see room36_data.asm) is a 64x48 grid of 4x4-pixel
; blocks, bit set = solid, built from exactly those placements the
; ORIGINAL treats as collidable: colour-byte bit 6 clear. (Bit 6 is
; Spectrum BRIGHT -- store_sprite_vars writes the room colour byte
; straight to frmattri and thence to screen attributes, and checkattri
; does `bit 6,a / ret nz`, i.e. bright = pass through. Torches and
; flames are bright and non-solid; dull brickwork is solid.)
;
; Dizzy's collision box is deliberately NARROWER than his 24px sprite --
; his boxing-glove hands stick out either side and shouldn't wedge him
; on ledges. Feet probes are spread across his boots.
CM_COLS      equ 64
CM_STRIDE    equ 8      ; bytes per mask row (64 cols / 8 bits)
; T0187: 192 rows of ONE PIXEL, not 48 of 4px. Lives in boot-transient
; TITLE_RAW_BUF scratch (1466 bytes were spare), so it costs nothing from
; the delivery budget, and the rasteriser already walked every ink pixel
; -- only the clear-loop grew.
CMASK_BYTES  equ CM_STRIDE*192  ; CUR_ROOM_CMASK's size; also sizes the
                                 ; shrunken title scratch (T0147)
; T0055: the side probes are the source's own, not insets. X-ALL.TXT
; probes ONE column each side: `checkleftside` (~6584) uses `ld a,(x)`
; and `checkrightside` (~6621) `ld a,(x) / add a,eggwidth-1`. eggwidth
; is 6 and x is in 4-pixel units (T0050), so those are dizzy_x + 0 and
; dizzy_x + 20 in pixels -- the outermost 4px column at each edge of his
; 24px sprite. This port had 5 and 18, one 4px block inside each, which
; let him push 4px into a wall on either side before stopping.
BODY_L       equ 0      ; left probe: the source's own `ld a,(x)`
BODY_R       equ 20     ; right probe: `x + eggwidth-1` units = +20px
; REACH_MARGIN: extra px actor_hit (actors.asm) extends Dizzy's own
; collision top upward by, beyond his tallest animated frame. Found via
; playtest sweep: pickup worked fine near the loaf/jug (y=144) but never
; near the apple (y=136) -- traced to a real, if small, gap: even
; Dizzy's TALLEST possible frame (dizzy_frame_heights' max, 21px) puts
; his computed head-top 3px short of the apple sprite's own bottom
; edge. The source uses a FIXED eggheight=18 (smaller still) for this
; same check, so blindly copying that would make the gap WORSE, not
; better -- not applied for that reason (see NOTES.md). This is a
; small, deliberate forgiveness margin instead, not a fidelity claim:
; enough to close the specific 3px gap with a little room to spare,
; shared by actor_hit's one caller-independent formula (pickup AND the
; rat's kill-on-contact test both use it) rather than a pickup-only
; special case, since duplicating the box math for one caller wasn't
; worth it for a few pixels of slop that's imperceptible either way.
REACH_MARGIN equ 4
; T0061: the foot probes are the source's own columns. `checkline`
; (X-ALL.TXT ~6672) sets lookx = x+1 and steps it `eggwidth-2` = 4
; times, so the floor/ceiling test reads 4x4 columns x+1, x+2, x+3, x+4
; in 4-pixel units -- pixels x+4 through x+19, contiguous. This port
; probed 6/12/17, which lands on columns +1, +3, +4 and SKIPS +2: a
; ledge only covering pixels x+8..x+11 held Dizzy in the original and
; dropped him here. Four probes at 4/8/12/16 are exactly the source's
; four columns.
FOOT_L       equ 4
FOOT_ML      equ 8
FOOT_M       equ 12
FOOT_R       equ 16

; X-ALL.TXT's own `updatedizzy` (Dizzy's animation/sequence update) runs
; off the raw 50Hz interrupt, gated by an `eggcount` divider of 4 -- i.e.
; the TRUE original animation rate is 50/4 = 12.5Hz. That is a different
; subsystem from the ~16.7Hz `clocklp` rate this port's mainloop pass is
; calibrated against (clocklp paces ROOM/actor updates, not Dizzy's own
; animation) -- conflating the two was the bug. At this port's current
; ~17.1 passes/sec (see the overclock/pacing section in NOTES.md),
; ANIM_DIVIDER=1 (every pass, ~17.1Hz) lands much closer to the real
; 12.5Hz target than the old ANIM_DIVIDER=4 (~4.3Hz, roughly a third of
; the correct speed -- this was reported as "idle animation feels slow").
; No integer divider hits 12.5Hz exactly against a 17.1Hz pass rate; 1
; errs toward faster/livelier rather than reintroducing the sluggishness.
ANIM_DIVIDER equ 1      ; must be a power of 2 (see mainloop's ANDB mask)
                         ; -- animation frame-steps once every this-many
                         ; mainloop passes, decoupled from movement/redraw
                         ; speed. Untuned; adjust if idle blink still
                         ; looks too fast/slow.

; --- CPU speed and frame pacing -------------------------------------
; OVERCLOCK: set SAM's R1 bit ($FFD7 -- the address BASIC's famous
; `POKE 65495,0` writes). MEASURED in emulated time: exactly 2x, taking
; this port from 13.8 to 27.5 mainloop passes/sec, with MAME's rendered
; video output still correct (compared snapshots side by side, not just
; framebuffer bytes -- reading framebuffer memory would look fine even
; if the VDG couldn't display it).
;
; T0073: OFF by default. It bought headroom while the frame budget was
; genuinely tight, but T0064's profiling (after the placement-scan,
; clear_and_blit, and blitdizzy optimizations) put room 36 at 47.6ms of
; a 66.7ms frame AT 1x -- comfortable, with the heaviest room (36, fire
; lit) still holding 15.0 passes/sec. The port no longer NEEDS the
; speed-up, and it's the one thing in this whole codebase whose safety
; margin can't be verified in MAME: double-speed operation is
; documented as marginal on some real CoCo2s depending on RAM chip
; speed, an analog concern the emulator has no way to reproduce.
; Nothing else here trades a real risk for a benefit that's no longer
; needed. Can still be turned back on with `-DOVERCLOCK=1` (or by
; editing the equ below) if a future room's frame cost demands it.
;
; CAVEAT, measured not assumed: room 35 (water tiles, no fire) drops
; from a flat 15.0 to 14.0 passes/sec at 1x -- the same "spike tips a
; pass into a 5th field" mechanism T0064 already documented, just
; visible again now that 1x halves the spare headroom that used to
; absorb it. draw_water has no cb_needed-style damage-rect gate the
; way draw_flames does; deliberately NOT added one here after checking
; why it wouldn't help -- see NOTES.md T0073. Judged an acceptable
; trade against a real-hardware safety unknown; revisit if room 35
; ever gets its own reported stutter.
;
; Only R1 works: measured R0 alone ($FFD5) and R0+R1 together both HANG
; the machine outright (0 passes/sec), so this is specifically the R1
; bit, not "any rate bit".
        ifndef OVERCLOCK
OVERCLOCK    equ 0
        endif

; FRAME_PULSES: extra 60Hz vsync waits per pass, so the speed-up buys
; CONSISTENCY rather than a game that plays too fast. The ZX original
; paces itself to 16.7 updates/sec (X-ALL.TXT clocklp waits 3 ticks of
; a 50Hz clock); uncapped at 2x this port runs 27.6/sec, well past that.
;
; MEASURED, overclocked (MAME, emulated time, 8s runs):
;   0 pulses -> 27.6/sec   2 pulses -> 17.1/sec   <- closest to 16.7
;   1 pulse  -> 24.0/sec   3 pulses -> 13.3/sec
;
; DELIBERATELY tied to OVERCLOCK. These are unconditional waits, not a
; deadline check, so they cost their full time whether or not the pass
; had headroom to spare: measured without the speed-up, the same 2
; pulses drag 13.3/sec down to 9.6/sec. Pacing is only correct when
; there is surplus speed to give back. If OVERCLOCK is ever switched
; off, this must go to 0 with it -- hence the conditional rather than a
; second number to remember to change.
; T0064: RETIRED -- 0 in both cases now. These were unconditional waits
; from before T0051's real pacing loop existed, and the two mechanisms
; do the same job: the budget loop in redraw's tail already holds each
; pass to FRAME_FIELDS field boundaries, and it COUNTS these waits (they
; bump field_ctr), so with them the loop simply waits less. They are not
; free, though: being unconditional they still cost their full time on a
; pass that has ALREADY overrun its budget, which is exactly the pass
; that could least afford it -- a heavy frame paid two more fields on
; top. Left as an `equ` rather than deleted so the measurements in this
; comment block still mean something.
        if OVERCLOCK
FRAME_PULSES equ 0
        else
FRAME_PULSES equ 0
        endif

DELAY_COUNT  equ 1      ; effectively disabled. This was an artificial
                         ; spin to pace movement back when a frame was
                         ; cheap; measured in emulated time (MAME,
                         ; -seconds_to_run, host-independent) it was
                         ; costing ~19% of the frame budget doing
                         ; literally nothing, while the port was already
                         ; running BELOW the original's own pace.
                         ; Reference: the ZX original waits for 3 ticks
                         ; of a 50Hz clock (X-ALL.TXT clocklp, "main
                         ; loop cycle time 1/50 secs unit") = 16.7
                         ; updates/sec. This port measured 9.8/sec
                         ; before this round's optimisations, 13.8 after
                         ; -- so there is no headroom to spend on an
                         ; idle spin. If a future build ever exceeds
                         ; 16.7, add real vsync-counted pacing here
                         ; (wait N pulses since the last frame) rather
                         ; than restoring a fixed cycle count, so speed
                         ; stays scene-independent the way the
                         ; original's clock-based wait does.

        if TAPE_ROOMS
; T0225b (L3): the TAPE build runs `start:` from the spare tail of framebuffer A
; ($574F-$57FF at load time: after the staged block A, before the $5800 block). It
; is boot-only code that finishes before anything draws; the tape EXEC address is the
; DECB trailer (`end start`), so it follows. new_game stays at $0E00, so the 136 B
; `start:` used to occupy fall off the END of the resident block (LOW3 grows). Parked at
; $cc00 in the raw measurement pass so it cannot pollute the raw image. The -run build
; keeps `start:` at $0E00 (BASIC's EXEC address) and its own jsr show_title / nibswap order.
TAPE_START_ORG equ $5772        ; T0259: was $5760 -- block A (packed) grew 18 B (the movingdata index in v2 of the pickupables); start: still ends by $5800 (141 B)
        ifdef STAGE_GEN
        org $cc00
        else
        org TAPE_START_ORG
        endif
        else
        org $0e00
        endif

start
        orcc #$50       ; disable IRQ+FIRQ -- BASIC's own interrupt handler
                         ; (keyboard scan, cursor blink, ~60Hz) is still
                         ; installed and active since we never touched it;
                         ; left enabled, it can fire mid-loop during the
                         ; screen clear/blit and interfere with SAM/PIA
                         ; state we depend on. Only visible at real-time
                         ; execution speed, not under -no-ratelimit (which
                         ; races through faster than one IRQ tick) -- see
                         ; NOTES.md "Slice: room 36" for the full story.

        ; T0036: explicit stack init, added when a second staged room
        ; (room 53) made the combined staging area big enough that
        ; relying on BASIC's own leftover stack pointer (observed
        ; ~$03D3, never actually guaranteed by anything) got too close
        ; for comfort. $0100 gives this code's own stack $0000-$00FF
        ; (256 bytes -- generous for how shallow this port's own call
        ; depth actually runs; nothing here recurses beyond the message
        ; VM's GOSUB, itself bounded by hand-authored message streams)
        ; and leaves $0100 upward entirely free for staging, clear of
        ; both the stack below and `start:`'s own $0E00 above.
        lds #$0100

        ; --- Ensure PIA0 side B's 60Hz pulse (used by wait_vsync for
        ; tear-free buffer flips) is enabled -- likely already true
        ; from BASIC's own boot, set explicitly rather than assumed
        ; (Inman & Inman ch.7 "Interrupts", p.159). ---
        lda #$35
        sta $ff03

        ; --- SAM V0-V2 = 110 (6R/6C mode family) ---
        ; STA, not LDA -- a real/documented SAM strobe is address-
        ; triggered regardless of read/write, but every register-level
        ; theory tried so far still garbles, and this is the one access
        ; type never tried. Cheap to test, forces a real write cycle.
        sta $ffc0
        sta $ffc3
        sta $ffc5

        ; --- SAM F0-F6: framebuffer at $4000 (512-aligned: $4000/512=32=%0100000) ---
        sta $ffc6
        sta $ffc8
        sta $ffca
        sta $ffcc
        sta $ffce
        sta $ffd1
        sta $ffd2

        ; --- PIA1 $FF22: mode nibble=$F, i.e. PB7-PB4 = A/G=1, GM2=1,
        ; GM1=1, GM0=1 -> RG6: 256x192, 1 bit/pixel. That IS PMODE4 and
        ; it is what every byte of this port's art assumes.
        ;
        ; DO NOT "correct" this to $E. A previous session did exactly
        ; that (commit a202efd, from a misreading of Inman & Inman table
        ; 4-2) and it stood for days: $E is GM=110 = CG6, a 128x192
        ; FOUR-COLOUR, 2-bits-per-pixel mode. In CG6 the VDG reads our
        ; 1bpp art as pixel PAIRS, so half the horizontal resolution is
        ; thrown away and black/white becomes buff/cyan/magenta/orange
        ; mush. That single wrong nibble is the whole reason the port's
        ; art looked far worse than the Spectrum original it was copied
        ; from, and it survived so long because it was only ever
        ; "verified" by reading $4000 back over GDB -- which decodes the
        ; buffer as 1bpp and therefore CANNOT see a mode error at all.
        ; See NOTES.md T0028. CSS=1 (bit3) selects the buff/black set.
        ; ---
        ; --- CPU speed-up (see OVERCLOCK above) ---
        if OVERCLOCK
        sta $ffd7
        endif

        lda $ff22
        anda #$07
        ora #$f8
        sta $ff22

        ; T0088: DAC sound enable, PIA1 CB2. Verified recipe -- a
        ; calibrated square-wave tone measured via MAME's -wavwrite and
        ; harness/audiocheck.py's zero-crossing count, not assumed from
        ; a datasheet read alone. See play_tone's own header for the
        ; timing model this unlocks.
        lda $ff23
        ora #8
        sta $ff23

        ; --- T0041/all-RAM investigation: engage the SAM's all-RAM
        ; mode and relocate rooms 52+53's staged data up into it.
        ; NOTES.md has the full diagnostic writeup -- MAME-verified
        ; before this was ever written into the real game: $8000+
        ; becomes genuine writable RAM, $0000-$7FFF is completely
        ; untouched (no bank swap), and both the SAM's own control
        ; registers and the PIA stay live/functional throughout
        ; (confirmed by successfully switching back via $FFDE, and by
        ; $FF03's vsync flag continuing to change on its own over real
        ; elapsed time rather than freezing like plain RAM would). Any
        ; write to $FFDF sets the TY bit -- write-only latch, value
        ; ignored, same mechanism as every SAM register set above;
        ; $FFDE clears it back to normal ROM mode.
        ;
        ; This data can't be loaded directly at $8000 -- BASIC's own
        ; CLOADM runs entirely BEFORE this code ever executes, still in
        ; normal ROM mode, so a block targeted at $8000+ would silently
        ; fail to write (ROM ignores it). It's staged at $0100 instead
        ; (T0036: room 53 made this too big for the $0500 gap room 52
        ; alone used -- see the staging block's own comment; `lds
        ; #$0100` just above gives this code an explicit, controlled
        ; stack well clear of it) -- assembled via PHASE so every label
        ; inside it (r52_room_place_count etc., referenced from
        ; load_room below) already resolves to its real, final $8000+
        ; address. Only the raw BYTES need moving; nothing that
        ; references them needs to know they were ever anywhere else.
        sta $ffdf
; T0153: this if/else's two branches MUST assemble to the same byte count.
; stage_pack.sh's pass 1 (raw, STAGE_LZ=0, produces the blobs pass 2 packs)
; and pass 2 (packed, STAGE_LZ=1, what ships) build this file with
; different branches taken here, so if the branches differ in length,
; low_resume and every label gameplay.asm etc. define after it lands at a
; DIFFERENT address in each pass -- yet the staged blocks (and anything
; frozen into them, e.g. jump tables) are generated from pass 1's
; addresses and never re-assembled against pass 2's. T0148 hit this with
; staged code, T0133 hit it with ordinary code nowhere near here (padding
; bisected to 11 bytes, one short of this branch's real 12-byte gap --
; TOOLCHAIN_SKEW_PAD, now removed). RELOC_BOOT_BYTES pins both branches to
; the larger (relocate-loop) size measured directly from a listing; the
; ifgt guards below fail the build loudly, in EITHER pass, the moment a
; future edit to either branch drifts them apart again, rather than
; silently reintroducing this class of bug.
RELOC_BOOT_BYTES equ 32
; T0235: per-room LZ-pack unpack buffer size (ROOM_UNPACK_BUF's own
; address is reserved much later, inside the tape-only region -- see its
; own comment) -- defined THIS early because roompack's --pack-room-data
; emits an `ifgt ROOM_RAW_LEN-ROOM_UNPACK_BUF_LEN error` guard directly
; inside EVERY packed room's own generated file, including the 28 base
; rooms staged into block A/B/C far above ROOM_UNPACK_BUF's own address
; -- `ifgt` needs this resolvable at the point it's read, not a forward
; reference. NOT auto-derived -- raise by hand if a bigger room is ever
; packed; the per-room `ifgt` guard catches an overrun either way (fails
; the build instead of corrupting the next room's data at runtime).
ROOM_UNPACK_BUF_LEN equ 315   ; T0235: measured max raw size so far (room 31, phase 1's 19 rooms) -- re-measured after phase 2 (28 base rooms) below
        if STAGE_LZ
_rb_start
        ldu #r8000_staged_start
        ldy #$8000
        jsr lz_unpack
        ldu #r9800_staged_start   ; T0067: the second block, from buffer B
        ldy #R9800_DEST
        jsr lz_unpack
_rb_end
        ifgt (_rb_end-_rb_start)-RELOC_BOOT_BYTES
        error "STAGE_LZ boot branch grew past RELOC_BOOT_BYTES -- raise the constant AND re-check the else branch's size"
        endif
; T0172: FILL, NOT RMB. `rmb` reserves space without emitting bytes, so the
; DECB output SPLITS into two segments here and the loader leaves these
; bytes AS IT FOUND THEM -- and boot falls straight through them into
; whatever the machine's RAM happened to hold. MAME's coco2b clears RAM to
; a benign pattern and booted fine for months; xroar's coco2bus does not,
; and the garbage at $0E52 decoded into a store that cleared PIA0 CRA's
; DDR-select bit ($FF01 $34 -> $BB), after which `lda $ff00` read DDRA
; (=0) instead of the keyboard -- every key reads as held, so the title
; mixer returned instantly (no music) and ti_release spun forever (freeze).
; NOP padding keeps the file one contiguous segment and makes the pad
; executable by construction.
        ifne RELOC_BOOT_BYTES-(_rb_end-_rb_start)
        fill $12,RELOC_BOOT_BYTES-(_rb_end-_rb_start)   ; NOPs: pad to match the else branch exactly
        endif
        else
_rb_start
        ldx #r8000_staged_start
        ldy #$8000
r8000_relocate
        lda ,x+
        sta ,y+
        cmpx #r8000_staged_end
        bne r8000_relocate

        ldx #r9800_staged_start   ; T0067: the second block, from buffer B
        ldy #R9800_DEST
r9800_relocate
        lda ,x+
        sta ,y+
        cmpx #r9800_staged_end
        bne r9800_relocate
_rb_end
        ifgt (_rb_end-_rb_start)-RELOC_BOOT_BYTES
        error "else (relocate-loop) boot branch grew past RELOC_BOOT_BYTES -- raise the constant to match and re-check the STAGE_LZ branch's padding"
        endif
        ifne (_rb_end-_rb_start)-RELOC_BOOT_BYTES
        error "RELOC_BOOT_BYTES is stale: the else branch no longer matches it exactly"
        endif
        endif

        if TAPE_ROOMS
        else
        jsr show_title           ; T0104: boot-only, lives in boot_code.asm
        endif
        ; --- T0052: build blit's nibble-swap table (see blit_shiftedlp).
        ; nibswap[(s+128) & 255] = ((s & $0F) << 4) | (s >> 4), the rotation
        ; being what makes the 6809's SIGN-EXTENDED `lda b,y` offset reach
        ; the whole 0..255 range from Y = nibswap+128. Built here rather
        ; than assembled so it costs no bytes in the load file. ---
        ldx #nibswap
        clrb                      ; B = s, 0..255
nib_lp
        tfr b,a
        anda #$0f
        lsla
        lsla
        lsla
        lsla
        sta nib_tmp               ; (s & $0F) << 4
        tfr b,a
        lsra
        lsra
        lsra
        lsra
        ora nib_tmp               ; ... | (s >> 4)  -- A = nibswap value
        pshs b
        addb #128                 ; rotate: entry for s lives at (s+128)&255
        ldx #nibswap
        abx                       ; abx is UNSIGNED, unlike b,y indexing
        sta ,x
        puls b
        incb
        bne nib_lp
        if TAPE_ROOMS
        ; T0225b (L3): nibswap is built BEFORE the title now (start: lives in framebuffer
        ; A, which the title's transpose overwrites, so nothing after show_title may run
        ; here). show_title never touches nibswap ($7F00, above the $6000-$77FF scratch),
        ; and returns straight into new_game through the pushed address.
        ldx #new_game
        pshs x
        jmp show_title           ; T0104: boot-only, lives in boot_code.asm
tape_start_end equ *
        ifgt tape_start_end-start-($5800-TAPE_START_ORG)
        error "tape start: runs past $5800 (the $5800 block) -- raise nothing, shrink start: or lower TAPE_START_ORG"
        endif
        org $0e00
        endif

        ; --- Dizzy's real spawn point, X-ALL.TXT `resetlives` (~1163):
        ; `ld a,46 / ld (startx),a` and `ld a,168 / ld (starty),a`.
        ;
        ; T0050: startx is in the source's own FOUR-PIXEL x units (see
        ; DIZZY_MAXX's comment above), so 46 units = 184 px -- this port
        ; had been reading it as 184-46 = 138px too far left. starty needs
        ; no conversion: y is plain pixels and is already the FEET (the
        ; original's own prtdizzy does `ld a,(dizy) / sub c` with c = the
        ; sprite height "giving the top corner ... rather than the bottom
        ; corner"), so 168 goes straight in. The old 170 matched neither
        ; that nor the "168+21=189" its own comment claimed.
        ;
        ; x=184 puts Dizzy in the troll's proximity box at the start of a
        ; new game, so the game opens with the troll shoving him back
        ; west -- that IS the original's opening beat, and it is what the
        ; real ZX capture shows: a fresh state parked in room 36 has
        ; Dizzy resting at ~84px, exactly one knockback west of 184. ---
;
; T0114: new_game. Everything from here on is what a NEW GAME needs, and
; game over (update_death) jumps here straight after showing the GAME OVER
; text screen -- the original's `quitted` does `jp titlescreen`, whose loop
; falls into resetmoving/resetcoins/resetcarrying/resetlives/nextlife. The
; stack is reset because that jump abandons update_death's call frame.
;
; T0146: no longer unpacks block C (rooms 39, 23) here -- that now runs
; once, at boot, from show_title (see logic_low.asm's unpack_c header);
; RC_DEST is read-only during play so it does not need refreshing per game.
new_game
        lds #$0100
        lda #2                    ; resetlives' 3 less nextlife's subfromlives:
        sta lives                 ; 2 spare eggs, 3 lives in all
        jsr force_redraw       ; T0221 (was 8 bytes inline)
        if TAPE_ROOMS
        clr rat_sv_hdr_a       ; T0225b: the save-under buffers live in the TITLE's transient
        clr rat_sv_hdr_b       ; tail now (clobbered by every title run): drop both before use
        endif
        lda #START_X
        sta dizzy_x
        lda #START_Y
        sta dizzy_y
        clr dizzy_dy
        clr upsidedown           ; T0125: X-ALL.TXT `quitted` rights the world
        clr well_mode
        clr dizzy_floor  ; spawn airborne and let real collision settle
                          ; him onto whatever is actually solid, rather
                          ; than asserting a hardcoded floor height
        lda #START_ROOM
        sta cur_room
        jsr set_checkpoint       ; T0050: resetlives seeds the checkpoint
                                  ; for the first life; enterroom takes
                                  ; over from the first room change on
        jsr actors_init  ; T0027: live actor table into RAM
        if TAPE_ROOMS
        jsr reset_tape_actors  ; T0234/T0236: actor+coin tape tables
        clr completedgame      ; T0236: X-ALL.TXT resetlives' own
                                 ; `ld (completedgame),a` (a=0)
        endif
        if SEED_INV
        jsr seed_inventory ; START_ITEM1..3 -- test aid, no-op when unset
        endif
        jsr gameplay_init ; T0029-T0032: hazards/death/rat/troll/puzzle state
        jsr load_room    ; T0023: point room_placements_ptr at room 36's
                          ; data and derive CUR_ROOM_CMASK before the
                          ; first redraw
        clr dizzy_seq
        clr dizzy_anim
        clr dizzy_ff
        lda #21
        sta dizzy_h      ; tallest frame; refreshed each mainloop pass

        ; SAM/PIA must be set BEFORE the graphics data is written, not
        ; after (Inman & Inman, "Assembly Language Graphics for the
        ; TRS-80 Color Computer", ch. 4, p.70: "This must be done before
        ; the data bytes are entered into the graphics memory." An
        ; earlier reorder experiment tried the opposite order on a
        ; theory about switching modes onto stale RAM -- it didn't fix
        ; the garbling and contradicts this documented-correct order,
        ; so reverted back to it.)
        jsr redraw
        ; T0114: X-ALL.TXT `nextlife` runs at the start of EVERY game, not
        ; only after a death: subfromlives, starteggres, starttune 1. The
        ; "new life" jingle plays with the room already on screen.
        ldd #tune1_notes
        jsr play_tune

        ; (T0025's prtmessage self-test lived here and is verified done --
        ; see NOTES.md for the capture. test_msg is kept as a regression
        ; fixture for the message VM; dialogue T0029 is its real caller.)

; --------------------------------------------------------------------
; mainloop (T0019/T0021, physics/animation per NOTES.md "Recover:
; Dizzy's own movement/physics/collision/animation" and "redo the
; art"): scan keys, move Dizzy horizontally, apply jump/gravity
; vertically against room 36's flat floor, pick this frame's animation
; sprite (now the hand-crafted redesigned set, not the extracted
; Spectrum data -- see newdizzy_frames.asm), redraw, repeat. Jump is
; edge-detected for free: it only triggers while dizzy_floor=1, so
; holding the key down doesn't re-trigger mid-air.
; --------------------------------------------------------------------
mainloop
        if FLOPPY
        jsr save_poll            ; T0242: S = quick save, L = quick load (floppy_save_res.asm)
        endif
        ; T0051: the frame's LOGIC half needs field-boundary polls just as
        ; much as its drawing half does. Without them this stretch is a
        ; blind spot: boundaries that pass here go uncounted, the pacing
        ; loop below thinks less time has elapsed than really has, and it
        ; then waits an extra whole field -- which showed up as light
        ; scenes settling at 13.6 passes/sec against a 15 target.
        jsr tick_poll
        jsr build_solid_actors   ; T0103: once a pass, not once a probe
        if PROFILE
        lda #1
        sta prof_slot
        endif
        jsr scankeys
        lda killed               ; T0059: `checkkeys` returns with left/
        beq ml_keysok            ; right/jump/fire all zeroed while dead
        clr keyflags
ml_keysok
        if PROFILE
        lda #2
        sta prof_slot
        endif
        jsr rng_step              ; feeds rat_newdir's timing -- see its own comment
        jsr tick_poll
        if PROFILE
        lda #3
        sta prof_slot
        endif
        jsr try_pickup           ; T0027: DOWN picks up/drops -- the apple-
                                    ; ->troll and jug->fire puzzles are now
                                    ; checked from WITHIN a drop, not polled
                                    ; here every pass -- see
                                    ; check_drop_triggers (gameplay.asm)
        if PROFILE
        lda #4
        sta prof_slot
        endif
        ; T0237: the actors' LOGIC (actors_tick: rat .. daisy1, water/fire hazards)
        ; runs once per pass plus once more every 3rd pass (actor_acc counts 3..1).
        ; On the ZX the main loop (all actors, flames, water: X-ALL.TXT maingamelp)
        ; ticks every 3rd interrupt and Dizzy every 4th (eggcount): 4 actor updates
        ; per 3 Dizzy updates.  One port pass = one Dizzy update.  Drawing stays
        ; once per pass.
        jsr actors_pass
        if TAPE_ROOMS
        lda completedgame
        beq ml_notwon
        ; X-ALL.TXT mainloop's own `ld a,(completedgame)/and a/
        ; jr nz,quitted` (line 1357) -- same title-return path
        ; update_death's own gp_ud_gameover tail uses.
        jsr show_title_resident
        jmp new_game
ml_notwon
        endif
        ; T0133: update_welllid removed -- its trigger only fires when the
        ; crowbar is dropped in the box now (check_drop_trigger's
        ; cdt_crowbar), so there is nothing left to poll every frame.
        if DEBUG_PROX_KEYS
        jsr debug_prox_keys      ; T0133: 'D'/'F' fire the drop-triggers
        endif
        jsr update_death
        if TAPE_ROOMS
        jsr tape_drunk_tick      ; T0230 (tape_talk_code.asm): checkifdrunk X:2947
        endif
        jsr tick_poll

        if PROFILE
        lda #11
        sta prof_slot
        endif
        ; T0089 follow-up: RE-SAMPLE the keyboard here, immediately
        ; before the only code that consumes it. The pass polls once at
        ; the top (line ~717), but everything between there and here --
        ; try_pickup and eleven hazard updates -- is dead time as far as
        ; input latency is concerned: a key pressed during it was missed
        ; by this pass's poll and had to wait for the whole rest of the
        ; pass, so it landed a FULL pass late.
        ;
        ; This does NOT make the game react more often -- movement still
        ; steps once per pass, at 15Hz, and that cadence is deliberate
        ; (FRAME_FIELDS=4, see its comment: 3 fields made Dizzy walk 1.6x
        ; the original and was its own playtest complaint). It only stops
        ; a press from missing the step it should have made. Measured
        ; with harness/inputlag.lua, which times a keypress to dizzy_dy
        ; going negative.
        ;
        ; The `killed` gate has to come with it -- the top-of-pass poll
        ; zeroes keyflags while dead (X-ALL.TXT's `checkkeys` returns
        ; left/right/jump/fire all zeroed), and re-reading the hardware
        ; without re-applying that would let a dead Dizzy walk.
        jsr scankeys
        lda killed
        beq ml_rescan_ok
        clr keyflags
ml_rescan_ok
        if TAPE_ROOMS
        jsr joy_walk             ; T0240: analog stick + fire OR'd into keyflags
        endif

        ; --- horizontal: left/right, also records direction (0/1/2)
        ; for animation selection ---
        ; While the troll's knockback is in the air, input is ignored --
        ; matches the original exactly (proxtrollrou's own comment:
        ; "call checkkeys ;;resets left & right"). Without this, holding
        ; the key that walked him into the troll in the first place
        ; would fight the launch's own dizzy_dir every single frame,
        ; and the tumble animation (seq4, selected below from
        ; dizzy_dir=1 + airborne) would flicker between the tumble and
        ; whatever the held key demands instead.
        tst troll_launching
        lbne ml_dirdone
        tst well_mode            ; T0125: no steering down the well either
        lbne ml_dirdone
        jsr tick_poll
        ; T0136: no air control. X-ALL.TXT reads left/right only from
        ; checkfloor -> bettercheckkeys, i.e. with a floor under Dizzy;
        ; otherwise `cantstop` keeps moving him by the LATCHED left/right.
        ; A jump (sequence 3..5) is stricter: `jumping` skips even
        ; checkfloor until the 8-step animation wraps to 0, and landing
        ; does not touch the animation (floorfound/storedizy), so landing
        ; mid-jump keeps him sliding the takeoff way for the rest of the
        ; cycle. dizzy_anim here is divided for display, so jump_anim
        ; counts the original's animation; jump_on stands in for
        ; "sequence >= 3", which only bettercheckkeys clears.
        tst jump_on
        beq ml_keys_floor
        lda jump_anim
        bne ml_jump_locked
        tst dizzy_floor
        bne ml_jump_free
ml_jump_locked
        inca
        anda #7
        sta jump_anim
        bra ml_keys_latched
ml_jump_free
        clr jump_on
ml_keys_floor
        tst dizzy_floor
        beq ml_keys_latched
        clra                     ; bettercheckkeys: left wins over right
        ldb keyflags
        bitb #4
        beq ml_keys_notleft
        inca
        bra ml_keys_set
ml_keys_notleft
        bitb #8
        beq ml_keys_set
        lda #2
ml_keys_set
        sta dizzy_dir            ; faces that way even if a wall blocks
ml_keys_latched
        lda dizzy_dir
        cmpa #1                  ; left
        bne ml_noleft
        lda dizzy_x
        cmpa #DIZZY_MINX
        bls ml_edgeleft          ; at the leftmost standing x -- stepping
                                   ; left is the room transition, exactly
                                   ; as the source's `cp 1 / jp z,goneleft`
                                   ; fires from its own x=2
        suba #WALK_STEP
        sta try_x
        clr cw_side              ; T0139: moving left tests x+BODY_L (0)
        jsr check_wall
        bne ml_dirdone           ; solid there: keep facing, don't move
        lda try_x
        sta dizzy_x
        bra ml_dirdone
ml_edgeleft
        ; T0036: room 53 (SNAP HAPPY GATOR) added as room 52's right
        ; neighbor -- two rooms now have a defined left-edge exit, so
        ; this is a real compare chain, not a single check, same shape
        ; check_wall/check_ground already use for cur_room-gated logic
        ; elsewhere in this file.
        lbra room_transition_left
ml_noleft
        cmpa #2                  ; right (A is still dizzy_dir)
        bne ml_dirdone
        lda dizzy_x
        cmpa #DIZZY_MAXX
        bhs ml_edgeright         ; can't step further right: edge of room
        adda #WALK_STEP
        sta try_x
        ldb #BODY_R              ; T0139: moving right tests x+BODY_R
        stb cw_side
        jsr check_wall
        bne ml_dirdone
        lda try_x
        sta dizzy_x
        bra ml_dirdone
ml_edgeright
        ; T0036: room 52 (THE ENTRANCE HALL) gains a right-edge exit to
        ; room 53 alongside room 35's existing one.
        lbra room_transition_right
ml_dirdone

        ; --- jump: "up" triggers it, but only from solid ground --
        ; naturally rejects holding the key down for repeat jumps ---
        lda keyflags
        bita #1                  ; up = jump
        beq ml_nojump
        lda dizzy_floor
        beq ml_nojump
        tst jump_on              ; T0136: landed mid-jump, keys not read yet
        bne ml_nojump
        lda #JUMP_DY
        sta dizzy_dy
        clr dizzy_floor
        lda #1                   ; X-ALL.TXT: animation=0, then cantstop's inc
        sta jump_on
        sta jump_anim
        jsr play_jump               ; T0089
ml_nojump

        ; --- troll knockback: continuous backward drift for the whole
        ; airborne tumble, not a one-time nudge. X-ALL.TXT's proxtrollrou
        ; forces the `left` key flag to 1, and while airborne the
        ; original SKIPS re-polling the real keyboard for several ticks
        ; in a row (`jumping:` jumps straight past `bettercheckkeys` to
        ; `cantstop` whenever `animation != 0`) -- so that forced flag
        ; keeps being read as "left held" across the whole arc, not just
        ; the tick it was set on. A single -4px nudge before liftoff
        ; (this port's first attempt) is nearly invisible next to the
        ; vertical launch; this instead steps him back WALK_STEP px every
        ; pass for as long as troll_launching holds, so the whole tumble
        ; visibly carries him away from the troll. Clamped short of the
        ; room's left edge so a knockback can't itself trigger the room
        ; 35 transition mid-tumble. ---
        tst troll_launching
        beq ml_noknockback
        lda dizzy_x
        cmpa #8
        bls ml_noknockback
        suba #WALK_STEP
        sta dizzy_x
ml_noknockback
        jsr well_air             ; T0125: the well's pinned rise / jump-out drift

        ; --- gravity + vertical motion against the real collision mask.
        ; Moves ONE PIXEL AT A TIME and re-probes, so a fast fall can't
        ; tunnel through a thin platform (dy reaches 7, and floor slabs
        ; are only ~8px thick). ---
        ; X-ALL.TXT `checkbottomside` does NOT start the floor search at
        ; the feet. It lifts Dizzy STEP_UP pixels first and scans down
        ; from there, with a budget of dy+STEP_UP:
        ;
        ;   slowfall  add a,4        ;; b = dy + 4
        ;             ld b,a
        ;             ld a,(y) / sub 4 / ld (y),a    ;; lift
        ;   ...lp     call checkline / jr nz,floorfound / inc y / djnz
        ;
        ; That lift IS the step-climbing mechanic: walk into anything up
        ; to STEP_UP tall and this frame's search finds its top and
        ; stands him on it, no jump. On flat ground it is a no-op -- the
        ; lift of 4 is immediately undone by the scan finding the same
        ; floor 4px down. Taller obstacles never get walked into, because
        ; check_wall blocks first (see its comment; the two are a matched
        ; pair). Runs EVERY frame, grounded or not, exactly as the source
        ; does -- there is no separate "am I still standing" short-circuit
        ; there, and having one here is what removed the climb.
        lda dizzy_dy
        cmpa #FALL_CAP
        bge ml_dycapped
        inca
ml_dycapped
        sta dizzy_dy
        bmi ml_moveup            ; rising: checktopside, no lift

        adda #STEP_UP            ; scan budget = dy + STEP_UP
        sta vstep
        lda dizzy_y
        sta pre_y                ; T0081: feet before this pass's lift
        suba #STEP_UP            ; ...starting STEP_UP above the feet
        sta dizzy_y
        clr dizzy_floor          ; re-established below iff a floor is found
ml_downlp
        jsr check_ground
        bne ml_floorfound
        lda dizzy_y
        cmpa #BOT_TRANSITION_Y
        blo ml_down_notrans
        lbra room_transition_down
ml_down_notrans
        lda dizzy_y
        cmpa #191
        bhs ml_landed            ; bottom of screen acts as solid
        inca
        sta dizzy_y
        dec vstep
        bne ml_downlp
        bra ml_vertdone
        jsr tick_poll

        ; T0068: X-ALL.TXT's `floorfound` (~6559) -- reached from the SAME
        ; grounded/step-climb scan `ml_down_notrans` above continues, not
        ; only from an actual jump -- does `ld a,(y) / cp 66 / jp c,goneup`
        ; before ever landing. A staircase whose steps are each shallow
        ; enough for STEP_UP (walked, not jumped) can carry Dizzy's feet
        ; below TOP_TRANSITION_Y without dizzy_dy ever going negative, and
        ; this port's up-transition test lived ONLY in `ml_moveup`
        ; (the jump path, dy<0) -- so climbing a staircase like room 51's
        ; or room 53's all the way to its top left him standing there,
        ; below the threshold, with no transition and nothing stopping
        ; him walking off the far side. Real playtest: "on 53 he can
        ; climb over the top edge and drop on the other side of the
        ; crocodile" and "on 51 I cannot get dizzy to jump to the room
        ; above" -- both rooms have a staircase reaching this height by
        ; walking; jumping FROM up there did already transition
        ; correctly (verified), which is what pointed at the GROUNDED
        ; path being the one missing the check, not the transition
        ; itself.
ml_floorfound
        lda dizzy_y
        cmpa #TOP_TRANSITION_Y
        bhs ml_landed             ; y>=66: a normal landing (source's
                                    ; y==66 "no-op" case folds in here too)
        ; T0081: feet above the line. The SOURCE always leaves the room
        ; here, so it never has Dizzy standing this high -- but when the
        ; room above isn't in this build the transition is denied and
        ; T0076 only stops him RISING, which still left him standing on
        ; room 51's top step with his whole body above the play window
        ; ("dizzy can still go beyond it", with his sprite drawn over
        ; the banner). Refuse the climb instead: put his feet back where
        ; they were before this pass's step-up and land there. That is
        ; the same "an unbuilt neighbour is an edge you can't walk
        ; through" rule check_wall already gives the horizontal edges.
        lda cur_room
        adda #16
        anda #127                ; the source's own `and 127`
        jsr room_exists
        tsta
        bne ml_ff_transition
        lda pre_y
        sta dizzy_y
        bra ml_landed
ml_ff_transition
        lbra room_transition_up
ml_landed
        clr dizzy_dy
        clr well_mode            ; T0125: any landing ends a well sequence
        ; T0236: landing does NOT end the jump's key lockout. X-ALL.TXT keeps it
        ; until the 8-step animation wraps (`jumping` -> cantstop while
        ; animation != 0) REGARDLESS of floor, so a jump that lands off the
        ; 8-update grid keeps sliding in the latched direction (from a settled
        ; start the original lands at x=48 with animation=1 and slides 7 more
        ; steps to x=76; the port does the same, step for step). jump_on/jump_anim
        ; are released only by ml_jump_free (animation wrapped to 0 AND a floor).
        ; History (T0196's clear-on-landing, and why it was wrong): NOTES.md T0236.
ml_keeplock
        lda #1
        sta dizzy_floor
        clr troll_launching       ; landed -- give control back, and
                                   ; re-arm the knockback for next time
        bra ml_vertdone

ml_moveup                        ; rising: step up |dy| pixels
        nega
        sta vstep
ml_uplp
        jsr check_ceiling
        bne ml_bonk
        lda dizzy_y
        cmpa #TOP_TRANSITION_Y
        bhs ml_up_notrans
        lbra room_transition_up
ml_up_notrans
        lda dizzy_y
        deca
        cmpa dizzy_h
        blo ml_bonk              ; head would leave the top of the screen
        sta dizzy_y
        dec vstep
        bne ml_uplp
        bra ml_vertdone
ml_bonk
        ; T0195: do NOT zero dizzy_dy. X-ALL.TXT's checktopside, when
        ; checkline says blocked, falls to `updownback`, which is only
        ;     xor a / ld (floor),a
        ; -- it clears `floor` and leaves `dy` ALONE. Gravity's own
        ; `inc a` then walks dy back up (-7,-6,...,0,+1) and Dizzy stays
        ; airborne for the REST of the arc, gliding horizontally the
        ; whole way, before falling.
        ;
        ; Zeroing it ended the jump on the bonking pass, so a jump into a
        ; low ceiling landed almost immediately and then spent the rest
        ; of its 8-step animation sliding along the ground with no key
        ; held ("when Dizzy jumps diagonally he does a few steps after
        ; landing"). Measured, room 68 jumping right at the table from
        ; 36,176 with the key released:
        ;   ORIGINAL  airborne to x=72, lands 76, slides to 100
        ;   PORT      dy zeroed at x=44, lands 44, slides to 68
        ; Both slide -- that part is faithful (cantstop keeps the latched
        ; direction until the animation wraps). The bug was landing 32px
        ; early, which put the whole slide on the ground where it shows.
        clr dizzy_floor          ; updownback's own `ld (floor),a`
ml_vertdone

        ; --- sequence (which 8-frame table) + animation (which of the
        ; 8) + resolved sprite frame id, per NOTES.md's seq0-seq5 (now
        ; pointing at the redesigned frame set's own seqtab, same
        ; structure). base = 0 if grounded, 3 if airborne. ---
        ; T0059: the death animation. X-ALL.TXT's `updatedizzy1` runs
        ; this INSTEAD of picking a sequence from floor/direction:
        ;
        ;   killed and sequence 6 -> leave it alone, keep animating
        ;   killed and sequence 7 -> when animation reaches 7, pin it
        ;                            back to 6, so the last two frames
        ;                            hold instead of looping round
        ;   killed and sequence 0 -> animation = 0, sequence = 7: this
        ;                            is where the keel-over STARTS
        ;   killed, any other seq -> `and a / jr nz,notdeadyet`: carry
        ;                            on as normal until he happens to
        ;                            reach a standing sequence
        ;
        ; That last branch looks like an oversight and is not: dying
        ; mid-stride finishes the stride first, which is why death in
        ; the original never snaps.
        lda killed
        beq ml_notdead
        lda dizzy_seq
        cmpa #6
        beq ml_seqdone            ; already bobbing: nothing to change
        cmpa #7
        bne ml_notkeeling
        lda dizzy_anim
        cmpa #7
        bne ml_seqdone
        lda #6
        sta dizzy_anim
        bra ml_seqdone
ml_notkeeling
        tsta
        bne ml_notdead            ; mid-stride: let it finish
        clr dizzy_anim
        lda #7
        sta dizzy_seq
        bra ml_seqdone
ml_notdead

        lda dizzy_floor
        beq ml_airborne
        tst jump_on              ; T0236: still inside a jump's lockout: `sequence` stays 3..5 (the jump
        bne ml_airborne          ; frames keep cycling while he slides), only bettercheckkeys resets it
        clra
        bra ml_havebase
ml_airborne
        lda #3
ml_havebase
        adda dizzy_dir
        sta dizzy_seq
        jsr well_seq             ; T0125: sequence 8 while tumbling up the well
ml_seqdone

        ; dizzy_anim advances once every ANIM_DIVIDER mainloop passes,
        ; not every single pass -- decouples animation speed from
        ; movement/redraw speed (NOTES.md).
        ldb anim_div
        incb
        andb #ANIM_DIVIDER-1
        stb anim_div
        bne ml_animdone

        ldb dizzy_anim
        incb
        andb #7
        stb dizzy_anim

        ; T0118: footsteps come from the ANIMATION, as in X-ALL.TXT
        ; updatedizzy -- only reached on the ground (checkfloor), only while
        ; walking (sequence != 0), and only on frames where `ld a,
        ; (animation) / and 3 / srl a` sets carry, i.e. on every ODD frame. Frames 3
        ; and 7 give sndfx 1, the tap; frames 1 and 5 give sndfx 0, the thud
        ; (T0260: both now play, see play_footstep). They used to fire on
        ; every other PIXEL step instead, in the air too -- playtest: "more
        ; step sounds than steps" and "when he jumps there should be no
        ; walking sounds".
        bitb #1
        beq ml_nostep
        lda dizzy_floor
        beq ml_nostep
        lda dizzy_seq
        beq ml_nostep
        cmpa #3
        bhs ml_nostep             ; 3+ = airborne / dying sequences
        jsr play_footstep         ; B = dizzy_anim (odd)
ml_nostep

        ldb flame_ctr            ; T0026: 16-step flame cycle, ticked on
        incb                     ; the same divider as Dizzy's animation
        andb #15                 ; so both run at one consistent speed
        stb flame_ctr

        ldb water_ctr            ; T0032 follow-up: 4-step ripple cycle
        incb
        andb #3
        stb water_ctr
ml_animdone

        lda dizzy_seq
        ldb #8
        mul                      ; D = seq*8 (fits in B, seq max 5)
        addb dizzy_anim
        ldx #dizzy_seqtab
        abx
        lda ,x
        sta dizzy_ff

        ldb dizzy_ff             ; keep dizzy_h in step for ceiling probes
        ldx #dizzy_frame_heights
        abx
        lda ,x
        sta dizzy_h

        if PROFILE
        lda #12
        sta prof_slot
        endif
        jsr redraw
        if PROFILE
        lda #23
        sta prof_slot
        endif
        jsr show_pending_messages
        if PROFILE
        lda #24
        sta prof_slot
        endif
        jsr pace_frame

        lbra mainloop

; --------------------------------------------------------------------
; actors_tick (T0237): every actor/hazard LOGIC update of a mainloop pass,
; table-driven (smaller than the inline jsr list it replaced).  tick_poll
; between entries keeps the pacing loop's field count honest.
; actors_pass: once per pass; every 3rd pass the 4th-in-3 run: ticks again, resets the counter and
; advances the flame/water frames (updateflames/updatewater run in the
; same main loop in the original).
; --------------------------------------------------------------------
actors_tick
        ldx #actor_tab
at_lp   pshs x
        jsr [,x]
        jsr tick_poll
        puls x
        leax 2,x
        cmpx #actor_tab_end
        bne at_lp
        rts
actors_pass
        bsr actors_tick
        dec actor_acc
        bne ap_ret
        lda #3
        sta actor_acc
        bsr actors_tick
        ldb flame_ctr
        incb
        andb #15
        stb flame_ctr
        ldb water_ctr
        incb
        andb #3
        stb water_ctr
ap_ret  rts
actor_acc       fcb 3
actor_tab
        fdb update_rat,update_troll,update_flame_hazard
        fdb update_crocodile,update_portcullis
        if TAPE_ROOMS
        fdb dragon_swap          ; T0239: per-dragon asleep/swing (rooms 54/40)
        endif
        fdb update_dragon,update_dagger,update_armorog,update_lifts
        if TAPE_ROOMS
        fdb update_switch1,update_hawk,update_dragon40,update_log48,update_daisy1
        endif
        fdb update_water_hazard,update_fire_hazard
        fdb pickup_tick          ; X-ALL `usepickup`: counted by the main loop
actor_tab_end

; --------------------------------------------------------------------
; redraw: double-buffered. Draws the whole scene (clear + every room
; placement + Dizzy) into whichever 6K buffer is currently OFF-screen,
; then flips the SAM F4 bit to show it -- the viewer only ever sees a
; finished frame, never the mid-clear/mid-blit state, which is what
; caused the visible flicker before (NOTES.md "known good books"
; section). The now-off-screen buffer becomes next frame's draw
; target.
; --------------------------------------------------------------------
redraw
        lda cur_buf
        beq rd_intob   ; A is on screen -> draw into B, track bufB's history
        ldd #BUFA
        std draw_base
        lda bufA_last_x
        ldb bufA_last_y
        bra rd_havetrack
rd_intob
        ldd #BUFB
        std draw_base
        lda bufB_last_x
        ldb bufB_last_y
rd_havetrack
        sta old_dizzy_x
        stb old_dizzy_y
        lda upsidedown           ; T0125: latched every pass -- msg_begin
        sta fb_flip              ; clears it while a box is painted

        ; T0052: undo the rat's save-under FIRST, so the buffer is pure
        ; static art before anything is drawn into it. A buffer that is
        ; about to be fully repainted (the 255 sentinel) has saved bytes
        ; describing a screen that no longer exists -- drop them instead.
        lda old_dizzy_x
        cmpa #255
        bne rd_ratrestore
        jsr rat_sv_invalidate
rd_ratrestore
        if PROFILE
        lda #13
        sta prof_slot
        endif
        jsr rat_restore

        ; Damage rect = union of Dizzy's last position IN THIS BUFFER
        ; (two redraws ago, since buffers alternate) and his current
        ; position -- x in byte-columns (0-32), y in pixel rows (0-192).
        ; A buffer that's never been drawn into (old_dizzy_x sentinel
        ; 255) gets a full-screen damage rect instead, priming it once;
        ; every redraw after that only touches the small region around
        ; where Dizzy actually moved, skipping the ~60 placements that
        ; didn't change instead of redrawing all 63 every single time.
        lda old_dizzy_x
        cmpa #255
        bne rd_computedmg
        clra
        sta dmg_col0
        sta dmg_y0
        lda #FBWIDTH
        sta dmg_col1
        lda #192
        sta dmg_y1
        bra rd_cleardmg

rd_computedmg
        lda dizzy_x
        lsra
        lsra
        lsra
        sta new_col
        lda old_dizzy_x
        lsra
        lsra
        lsra
        sta old_col

        cmpa new_col
        bls rd_col0isold
        lda new_col
rd_col0isold
        sta dmg_col0

        lda old_col
        cmpa new_col
        bhs rd_col1isold
        lda new_col
rd_col1isold
        adda #4         ; worst-case 4-byte-wide footprint (shifted case)
        cmpa #FBWIDTH
        bls rd_col1ok
        lda #FBWIDTH
rd_col1ok
        sta dmg_col1

        ; dizzy_y is his FEET (bottom edge) -- the sprite extends UP from
        ; there by the current frame's height (14-21px, varies per
        ; frame). Rather than track each buffer's stale frame height
        ; too, just use the tallest possible frame (21) as a safe upper
        ; bound on how far up the damage rect needs to reach -- a little
        ; extra redrawn margin on shorter frames, never a gap.
        lda old_dizzy_y
        cmpa dizzy_y
        bls rd_y0isold
        lda dizzy_y
rd_y0isold
        cmpa #21        ; real sprite set's max frame height, restored
        bhs rd_y0sub
        clra
        bra rd_y0store
rd_y0sub
        suba #21
rd_y0store
        sta dmg_y0

        lda old_dizzy_y
        cmpa dizzy_y
        bhs rd_y1isold
        lda dizzy_y
rd_y1isold
        sta dmg_y1

rd_cleardmg
        if PROFILE
        lda #14
        sta prof_slot
        endif
        ; T0064: same hoist clear_and_blit got -- the row address (a
        ; `mul` and two adds) and the row width were recomputed for
        ; every row of the rect, ~50 cycles of setup to clear the three
        ; or four bytes Dizzy's own damage rect is usually wide. Now
        ; computed once, with X walked by a precomputed stride.
        ; T0125: flipped, the rect is clamped to the mirrored window --
        ; rows outside 48..183 would land in the banner or past row 191.
        ;
        ; T0237 (TAPE_ROOMS only): the UNFLIPPED path used to skip this
        ; whole clamp (`beq rd_noclamp`), which is exactly the clobber
        ; harness/banner_writers.lua's write-taps caught live: a buffer
        ; that has never been drawn into (the 255 sentinel, above) gets
        ; dmg_y0=0/dmg_y1=192 -- a full-screen rect -- and with no clamp
        ; that reaches straight into the banner rows every time a room
        ; changes. draw_ui's own former full-buffer banner repaint (see
        ; ui.asm T0237) was the thing papering over this. Now dmg_y0 is
        ; clamped to win_top UNCONDITIONALLY for TAPE_ROOMS (dmg_y1 is
        ; only clamped to FLIP_YEND when actually flipped, same as
        ; before -- the unflipped bottom bound, up to row 191, was never
        ; the problem: draw_border repaints that band fresh every pass
        ; regardless). The -run build (else) is BYTE-IDENTICAL to the
        ; original code -- see NOTES.md T0237.
        if TAPE_ROOMS
        tst fb_flip
        beq rd_topclamp
        lda dmg_y1
        cmpa #FLIP_YEND
        bls rd_y1ok
        lda #FLIP_YEND
        sta dmg_y1
rd_y1ok
rd_topclamp
        lda dmg_y0
        cmpa win_top
        bhs rd_y0ok
        lda win_top
        sta dmg_y0
rd_y0ok
        lda dmg_y0
        cmpa dmg_y1
        bhs rd_clrdone          ; nothing left inside the window
        else
        tst fb_flip
        beq rd_noclamp
        lda dmg_y1
        cmpa #FLIP_YEND
        bls rd_y1ok
        lda #FLIP_YEND
        sta dmg_y1
rd_y1ok
        lda dmg_y0
        cmpa win_top
        bhs rd_y0ok
        lda win_top
        sta dmg_y0
rd_y0ok
        lda dmg_y0
        cmpa dmg_y1
        lbhs rd_clrdone          ; nothing left inside the window
        endif
rd_noclamp
        ldb dmg_col1
        subb dmg_col0
        stb clr_width
        ldb #FBWIDTH
        subb clr_width
        jsr fb_strideb           ; T0125: -32-w when flipped
        stb clr_stride

        ldb dmg_y0
        jsr fb_rowd              ; T0125: row 231-y when flipped
        tfr d,x
        ldb dmg_col0
        abx                      ; X = first row's first byte

        lda dmg_y0
        sta clr_row
        clra                     ; the byte being written
rd_clryloop
        ldb clr_width
rd_clrxloop
        sta ,x+
        decb
        bne rd_clrxloop
        ldb clr_stride
        leax b,x                 ; X -> next row's first byte (T0125: signed)

        jsr tick_poll            ; T0051: a full-screen prime clear runs
                                  ; well past one field on its own
        clra                     ; tick_poll reads $ff03 into A
        ldb clr_row
        incb
        stb clr_row
        cmpb dmg_y1
        bne rd_clryloop
rd_clrdone

        ; only re-blit placements whose bounding box overlaps the
        ; damage rect (AABB test using each placement's own sprite
        ; header for width/height -- offset 2,U = bpr, 1,U = height)
        if PROFILE
        lda #15
        sta prof_slot
        endif
        jsr redraw_placements_dmg
        if PROFILE
        lda #16
        sta prof_slot
        endif
        jsr draw_coins           ; T0057: before the actors -- room 52's
                                  ; coin hides UNDER the railing actor
        if TAPE_ROOMS
        jsr draw_coins_tape      ; T0236: the tape-only region's own table
        endif

        jsr tick_poll
        if PROFILE
        lda #17
        sta prof_slot
        endif
        jsr draw_flames
        if PROFILE
        lda #18
        sta prof_slot
        endif
        jsr draw_fire_overlay
        if PROFILE
        lda #19
        sta prof_slot
        endif
        jsr draw_water
        jsr draw_dragon           ; T0071: room 54's dragon
        if PROFILE
        lda #20
        sta prof_slot
        endif
        jsr draw_actors
        if TAPE_ROOMS
        jsr draw_actors_tape      ; T0234: the tape-only region's own table
        endif

        ; T0062: DIZZY LAST. He used to draw here BEFORE flames/water/
        ; actors, so anything drawn afterward -- the troll, the rat, a
        ; wide flame tile -- painted straight over him with no way for
        ; his own ink to win back. Real playtest screenshot: standing in
        ; front of the stair room's balustrade, with no way to tell
        ; whether he was in front of it or behind it. The source doesn't
        ; have this problem at all -- Dizzy is drawn by `prtdizzy`, called
        ; off the 50Hz interrupt independently of the main loop's actor
        ; updates, so he's redrawn on his OWN cadence regardless of what
        ; the room just did -- but this port's redraw is one serial pass,
        ; and in a single pass "drawn last" is what "always on top" means.
        if PROFILE
        lda #21
        sta prof_slot
        endif
        jsr blitdizzy
        jsr tick_poll
        if PROFILE
        lda #22
        sta prof_slot
        endif
        jsr refresh_ui_text
        jsr draw_ui
        ; T0079: the play-area frame, LAST of all -- same "drawn last is
        ; what always-on-top means in a serial pass" reasoning T0062
        ; used for Dizzy. Keeps a placement redrawn near an edge from
        ; ever leaving a hole in the frame, and saves it needing a clear.
        jsr draw_border
        jmp rd_afterplaces        ; skip the routine body below -- fallthrough was here before it became a subroutine

; --------------------------------------------------------------------
; redraw_placements_dmg: re-blit every room placement whose bounding
; box overlaps [dmg_col0,dmg_col1)x[dmg_y0,dmg_y1) -- factored out of
; redraw() into a real subroutine so rat_clear_and_blit can call it too
; (with dmg temporarily pointed at the rat's OWN clear rect, not
; Dizzy's). The rat moves every pass outside Dizzy's damage rect
; entirely; clearing its old position with no equivalent "put back
; whatever static art was also there" step erased legitimate floor/
; wall/chest art that only Dizzy's own damage rect would ever have
; restored -- invisible until he happened to walk through that exact
; spot ("objects... show as blank, pop in when dizzy walks by"). Only
; became clearly visible once the rat's patrol range widened enough to
; sweep through areas with real background art in them.
; --------------------------------------------------------------------
redraw_placements_dmg
        ; T0064: start at the first placement that can reach the damage
        ; rect's top band, and stop as soon as one starts below its
        ; bottom. The list is emitted sorted by y with a 12-entry index
        ; of "first placement that can reach this 16px band" (roompack),
        ; which is what makes both ends of that valid.
        ;
        ; This used to walk all 63 of room 36's placements every pass --
        ; measured at 11.3ms of a 66.7ms frame at 1x CPU, the single
        ; biggest cost after the fire pit, and paid whether or not
        ; anything was near Dizzy. A damage rect his own size spans one
        ; or two bands.
        lda dmg_y0
        lsra
        lsra
        lsra
        lsra                     ; band = y >> 4
        asla                     ; 2 bytes per entry
        ldx room_place_bands_ptr
        ldx a,x                  ; X = first placement worth looking at
        cmpx room_placements_end
        bhs rd_placedone
; T0052: this scan runs over EVERY placement in the room (63 in room 36)
; on every single redraw, and most of them are rejected -- so the reject
; path is the hot path, and it used to go through memory for every
; intermediate: 8 stores and 10 loads to compute four bounds, then four
; more loads to compare them. ~130 cycles to say "no", 63 times a frame.
;
; Rewritten to keep everything in registers and to store the sprite's
; details ONLY once a placement has actually passed the test (the blit
; needs them in memory, but a rejected placement never needs them at
; all). The four bounds tests are also ordered cheapest-first, and the
; two that only need a register are done before anything is written.
rd_placelp
        ldu ,x++                 ; U = sprite header (w,h,bpr then bitmap)
        lda ,x+                  ; A = pixel x
        ldb ,x+                  ; B = y
        stx placeptr
        cmpb dmg_y1
        bhs rd_placedone         ; sorted by y: every later one is lower still

        ; Horizontal first, in A: col0 = x >> 3, col1 = col0 + bpr.
        lsra
        lsra
        lsra
        cmpa dmg_col1
        bhs rd_skipplace         ; starts at/right of the rect
        adda 2,u                 ; A = col1
        cmpa dmg_col0
        bls rd_skipplace         ; ends at/left of the rect

        ; Vertical, in B: y0 = y, y1 = y + height.
        cmpb dmg_y1
        bhs rd_skipplace         ; starts at/below the rect
        addb 1,u                 ; B = y1
        cmpb dmg_y0
        bls rd_skipplace         ; ends at/above the rect

        ; Only a placement that actually overlaps is worth writing out.
        stu blit_ptr
        ldx placeptr
        lda -2,x                 ; pixel x, re-read rather than kept.
        tfr a,b                   ; T0142: bit 0 is the mirror flag, T0163's
        andb #1                   ; DECORATIVE flag now rides bit 1 (used
        stb blit_mirror           ; only by load_room's mask derivation, but
        anda #$fc                 ; still has to be masked off HERE too --
        sta blit_x                ; placement x is a multiple of 4, so both
                                    ; bits are free and cost no extra byte.
        lda -1,x                 ; y
        sta blit_y
        jsr blit
rd_skipplace
        jsr tick_poll            ; T0051
        ldx placeptr
        cmpx room_placements_end
        blo rd_placelp
rd_placedone
        rts

rd_afterplaces
        ; remember Dizzy's new position as this buffer's history for
        ; next time it's reused, then wait for vsync and flip to show
        ; what we just drew. Without the wait, the F4 strobe can land
        ; mid-scan -- the viewer then sees the OLD buffer for the top
        ; part of the frame and the NEW buffer for the rest (classic
        ; unsynchronized page-flip tearing), which for a barely-moving,
        ; animating sprite looks exactly like two overlapping copies at
        ; slightly different frames -- reported by the user as "the
        ; character is duplicated... shifted to the right" once the
        ; per-frame mask fixes above made individual frames clean
        ; enough to tell apart (NOTES.md).
        ; T0051 pacing: hold here until FRAME_FIELDS field boundaries have
        ; passed since the previous flip, so the frame period is the same
        ; in every scene instead of "however long this scene's work took".
        ; ALWAYS waits at least once, which is what keeps the flip itself
        ; synced to a field boundary (the anti-tearing reason the single
        ; wait_vsync was here in the first place). A scene whose work
        ; genuinely overruns the budget just runs late -- no catch-up, no
        ; frame skipping, it simply degrades to its own natural rate.
        ; The wait comes FIRST, deliberately: the frame must always END on
        ; a field boundary, not merely once the budget is spent. Exiting
        ; the moment the count reaches the target leaves the flip landing
        ; mid-field, so the next frame starts out of phase, and the phase
        ; then drifts frame to frame -- constant work ends up straddling
        ; 4 boundaries sometimes and 5 others. Measured: room 35 settled
        ; at 13.7 passes/sec against a 15.0 target with the check first,
        ; and lands on 15.0 with the wait first. It also keeps the flip
        ; itself synced, which is the anti-tearing reason a wait was here
        ; before any of this pacing existed.
        if PACING
rd_pacelp
        if PROFILE
        lda #25
        sta prof_slot
        endif
        lda field_ctr
        cmpa #FRAME_FIELDS
        bhs rd_paced
        jsr wait_vsync
        bra rd_pacelp
rd_paced
        if PROFILE
        pshs a                   ; A holds field_ctr for the carry below
        lda #26
        sta prof_slot
        puls a
        endif
        else
        jsr wait_vsync            ; -DPACING=0: free-running, the pre-T0051
                                   ; behaviour. Only for profiling -- the
                                   ; pacing otherwise hides exactly the
                                   ; per-phase differences being measured.
        endif
        ; CARRY the surplus instead of clearing it. Clearing throws away
        ; the fraction of a field the frame overran by, so the frame's
        ; phase against the 60Hz field drifts and constant work ends up
        ; straddling 4 boundaries sometimes and 5 others -- measured as
        ; room 35 sitting at 13.7 passes/sec against a 15.0 target while
        ; room 36 hit 15.0 exactly. Subtracting the budget keeps the
        ; long-run average at exactly FRAME_FIELDS.
        ;
        ; Clamped to one frame of credit: a genuinely huge overrun (the
        ; full-screen redraw on a room change counts a dozen fields) must
        ; not buy several unpaced frames afterwards, which would read as
        ; a speed burst every time you walk through a door.
        suba #FRAME_FIELDS
        cmpa #FRAME_FIELDS
        blo rd_carryok
        lda #FRAME_FIELDS
rd_carryok
        sta field_ctr

        lda cur_buf
        beq rd_showb
        lda dizzy_x
        sta bufA_last_x
        lda dizzy_y
        sta bufA_last_y
        sta $ffce       ; showing B -> switch to A (F4 clear)
        clra
        sta cur_buf
        rts
rd_showb
        lda dizzy_x
        sta bufB_last_x
        lda dizzy_y
        sta bufB_last_y
        sta $ffcf       ; showing A -> switch to B (F4 set)
        lda #1
        sta cur_buf
        rts

; --------------------------------------------------------------------
; T0026: torch flames. A faithful port of `updateflames`/`printflame`
; (X-ALL.TXT 2238): one 16-step counter drives every flame in the room;
; bit 0 selects the tone variant and bit 1 the mirrored variant, giving
; the 4 pre-shaded sprites roompack emits per room.
;
; The original alternates the flame's COLOUR between attribute 70
; (yellow, bright) and 66 (red, bright). On a 1-bit target that becomes
; a genuine brightness flicker for free, because T0025's shading maps
; those two attributes to very different dither duty cycles (luminance
; 0.89 vs 0.30) -- the flame really does pulse bright/dim rather than
; sitting static.
;
; Each flame clears its own bounding box before drawing. It has to:
; `blit` composites with OR and can only ADD ink, and the damage-rect
; redraw only clears around DIZZY, so without this the animation frames
; would accumulate on top of each other into a solid blob.
; --------------------------------------------------------------------
draw_flames
        lda room_flame_count
        beq df_done
        sta flame_n
        ldx room_flames_ptr
        stx flame_ptr

        ; T0064: variant = the MIRROR bit only, so it changes every 2nd
        ; pass instead of every pass.
        ;
        ; The flame table has 4 entries, but 0/1 and 2/3 are BYTE-
        ; IDENTICAL bitmaps -- checked against the generated data, not
        ; assumed. In the original those pairs differ only by
        ; `printflame`'s `xor 6+64`, which recolours the ATTRIBUTE cell
        ; (free on a Spectrum, and meaningless on a monochrome PMODE4
        ; screen); the pixels themselves change only on the counter's
        ; bit 1, its vertical mirror. Keying the variant on bit 0 as
        ; well meant every pass looked like a change, forcing all 4
        ; tiles of the fire pit AND both torches through a full
        ; clear+blit for output that was provably identical. Half of
        ; the single most expensive thing in the frame, spent redrawing
        ; the same pixels.
        lda flame_ctr
        anda #2
        sta flame_var
df_novmirror
        ; Has the variant changed since this BUFFER was last drawn? The
        ; two buffers alternate, so each needs its own record -- see
        ; cb_needed for why this matters (41% of the frame budget).
        jsr flame_var_ptr
        lda flame_var
        cmpa ,x
        beq df_samevar
        sta ,x
        lda #1
        sta cb_force
        bra df_havevar
df_samevar
        clr cb_force
df_havevar

        lda flame_var
        asla                     ; fdb table: 2 bytes per entry
        ldx room_flame_tab_ptr
        leax a,x
        ldd ,x
        std flame_spr            ; -> chosen variant's (w,h,bpr) header

df_loop
        jsr tick_poll             ; T0051 field-boundary sampling
        ldx flame_ptr
        lda ,x+
        sta cb_x
        lda ,x+
        sta cb_y
        stx flame_ptr
        ldd flame_spr
        std cb_spr
        jsr cb_needed
        tsta
        beq df_skipone
        jsr clear_and_blit
df_skipone
        dec flame_n
        bne df_loop
df_done
        rts

; flame_var_ptr: X -> the per-buffer "variant currently drawn here"
; byte for whichever buffer redraw() is targeting this pass. draw_base's
; high byte identifies it ($40 = buffer A, $60 = buffer B).
flame_var_ptr
        lda draw_base
        cmpa #$40
        beq fvp_a
        ldx #flame_var_b
        rts
fvp_a
        ldx #flame_var_a
        rts

; --------------------------------------------------------------------
; draw_fire_overlay / update_fire_hazard: room 2's `fireout` overlay
; (T0032 follow-up -- corrects an earlier wrong guess. The FIRST
; attempt assumed "the fire" was just room 36's own nearest ambient
; torch and extinguished that; a real playtest reported no fire at all
; and no hazard, which sent this back to the original source. The
; ACTUAL mechanic, X-ALL.TXT `checkfireout` (~5491): room 36's own
; `roomsetup` draws ROOM 2's data as an EXTRA overlay pass on top of
; itself whenever `fireout` is still 0 -- room 2 is nothing but 4
; frame-115 flame placements clustered at floor height near the jug's
; own proximity box, forming a genuine fire PIT, not another torch.
; `proxjugrou` just sets the global `fireout` flag; once set,
; `checkfireout` stops drawing the overlay and the pit is gone.
;
; This port reproduces the same shape without the original's
; redraw-the-whole-room-twice approach: draw room 2's 4 flames as a
; SEPARATE animated list, gated on room 36 + fireout==0, using the
; same clear_and_blit/variant-selection code draw_flames already has
; (parameterised through flame_spr/flame_ptr/flame_n rather than
; duplicated). The hazard uses the shared hazard_scan the same way
; the water hazard does.
; --------------------------------------------------------------------
draw_fire_overlay
        lda cur_room
        cmpa #36
        bne fo_done
        tst fireout
        bne fo_done

        lda r2_room_flame_count
        beq fo_done
        sta flame_n
        ldx #r2_room_flames
        stx flame_ptr

        lda flame_ctr            ; T0064: mirror bit only -- see draw_flames
        anda #2
        sta flame_var
fo_novmirror
        ; Same per-buffer variant gate as draw_flames -- these 4 tiles
        ; were the single biggest slice of the frame budget (24% on
        ; their own, measured).
        jsr fire_var_ptr
        lda flame_var
        cmpa ,x
        beq fo_samevar
        sta ,x
        lda #1
        sta cb_force
        bra fo_havevar
fo_samevar
        clr cb_force
fo_havevar

        lda flame_var
        asla
        ldx #flame_table          ; T0121: the one shared flame set (was r2_flame_table)
        leax a,x
        ldd ,x
        std flame_spr

fo_loop
        jsr tick_poll             ; T0051 field-boundary sampling
        ldx flame_ptr
        lda ,x+
        sta cb_x
        lda ,x+
        sta cb_y
        stx flame_ptr
        ldd flame_spr
        std cb_spr
        if PROFILE
        lda #27
        sta prof_slot
        endif
        jsr cb_needed
        tsta
        beq fo_skipone
        if PROFILE
        lda #28
        sta prof_slot
        endif
        jsr clear_and_blit
        if PROFILE
        lda #29
        sta prof_slot
        endif
fo_skipone
        dec flame_n
        bne fo_loop
fo_done
        rts

fire_var_ptr
        lda draw_base
        cmpa #$40
        beq fivp_a
        ldx #fire_var_b
        rts
fivp_a
        ldx #fire_var_a
        rts

; --------------------------------------------------------------------
; draw_water: T0032 follow-up -- room 35's pool, missing entirely until
; a real playtest flagged it. Faithful to `updatewater`: a 4-step
; counter cycling frames 92-95 (the trigger frame, 91, is never itself
; drawn). Simplified from the original in one way, noted honestly: the
; original gives each water TILE its own independent counter (a real
; per-tile phase offset); this port shares one counter room-wide, a
; synchronized ripple instead of a staggered one. Visually close, much
; cheaper, and `clear_and_blit` makes the rest of this nearly free.
; --------------------------------------------------------------------
draw_water
        lda room_water_count
        beq dw_done
        sta water_n
        ldx room_water_ptr
        stx water_ptr

        lda water_ctr
        asla                     ; fdb table: 2 bytes per entry
        ldx room_water_tab_ptr
        leax a,x
        ldd ,x
        std cb_spr

dw_loop
        jsr tick_poll             ; T0051 field-boundary sampling
        ldx water_ptr
        lda ,x+
        sta cb_x
        lda ,x+
        sta cb_y
        stx water_ptr
        jsr clear_and_blit

        dec water_n
        bne dw_loop
dw_done
        rts

; --------------------------------------------------------------------
; T0071: draw_dragon -- room 54's dragon. update_dragon (gameplay.asm)
; has already computed this pass's state (dragon_swing, dragon_headfrm,
; dragon_fire, dragon_flame_x[]/dragon_flame_n); this just blits it.
;
; Unlike every other actor in this port, the dragon is SEVEN independent
; sprites (six neck segments plus the head) that can all move every
; single pass while awake, plus up to six more (the flames) while
; breathing -- none of them sharing a single fixed footprint the way
; the crocodile or the gate do. Giving each its own save-under (T0052's
; rat mechanism) would need seven separate per-buffer buffers; giving
; each a clear-only-the-new-position blit (like a plain static actor)
; would leave a trail of every position it passed through, the exact
; problem T0052/T0066/T0068 all exist to prevent.
;
; Cheaper than either: clear ONE fixed rectangle generous enough to
; contain every piece in every reachable position (DRAGON_BOX_*, sized
; from the swing range -8..16 and the flame extent, with margin), THEN
; blit everything fresh into it. Measured cost is a fraction of the
; full-screen prime clear (T0064) -- this box is 16 bytes x 56 rows
; against the screen's 32x192 -- and it only runs in this one room,
; only while the dragon is actually animating.
; --------------------------------------------------------------------
; T0071: tightened from a generous 128x56 guess after profiling showed
; the clear was the dragon's single biggest cost (21ms of a 66.7ms
; frame at 1x CPU). Computed exactly, not re-guessed: X spans the neck
; (pixel 156-184), the flames (72-148, +8 width -> 156) and the head
; (144-160) -- union 72-184, conveniently already byte-aligned (72=9x8,
; 184=23x8). Y spans the head (152-swing, swing -8..16, +16 height ->
; 136-176), the neck (152-b*swing/8, b<=6, +11 height -> 140-175) and
; the flames (head_y+8, +8 height -> 144-176, only while awake so
; capped at swing>=0's head_y range) -- union 136-176, rounded to 132-
; 180 for margin against an off-by-one in that derivation. 14 bytes x
; 48 rows against the old 16x56: about 25% less to clear every pass.
DRAGON_BOX_COL   equ 9      ; byte column 9 = pixel 72
DRAGON_BOX_ROW   equ 132
DRAGON_BOX_WBYTE equ 14     ; 112px wide (72..184)
DRAGON_BOX_H     equ 48     ; 132..180

draw_dragon
        lda cur_room
        if TAPE_ROOMS
        cmpa #40                 ; T0239: room 40's dragon draws the same way
        beq dd_inroom
        endif
        cmpa #54
        lbne dd_done
dd_inroom
        ; permanently retracted: the source's own `ret z` -- nothing
        ; left to redraw, ever, so leave whatever is already on screen.
        lda dragon_asleep
        beq dd_clear
        lda dragon_swing
        cmpa #-8
        lbeq dd_done

dd_clear
        lda #FBWIDTH
        ldb #DRAGON_BOX_ROW
        mul
        addd draw_base
        addd #DRAGON_BOX_COL
        tfr d,x
        ldb #DRAGON_BOX_H
        stb dd_rows
dd_clrrow
        ldb #DRAGON_BOX_WBYTE
        clra
dd_clrcell
        sta ,x+
        decb
        bne dd_clrcell
        ldb #FBWIDTH-DRAGON_BOX_WBYTE
        abx
        dec dd_rows
        bne dd_clrrow

        ; T0116: the neck is drawn EVERY pass, breathing or not. The source
        ; does skip printneck during a breath, but it never erases anything
        ; either (printmoving overwrites, nothing rubs out), so the neck
        ; drawn on the last pass before the breath simply stays on screen --
        ; which is what the real game shows (filmed in MAME, harness/
        ; zx_film.lua). This port clears DRAGON_BOX every pass, so skipping
        ; the neck here left the head floating with a gap behind it. The
        ; swing is frozen during a breath, so redrawing it is identical to
        ; leaving the old one.
        ;
        ; six segments, frame 111, fixed X (raw 76..71 -> pixel 176..156
        ; in steps of 4), Y = origin - b*swing/8 (findnecky, b=1..6).
        ldx #dragon_neck_x
        lda #1
        sta dd_b
dd_necklp
        ldb dd_b
        jsr dragon_necky          ; A = -(b*dragon_swing/8), signed
        adda #DRAGON_ORIGY        ; A = DRAGON_ORIGY - b*swing/8
        sta blit_y
        ldd #aspr_111_w
        std blit_ptr
        lda ,x+
        sta blit_x
        pshs x
        jsr blit
        puls x
        inc dd_b
        lda dd_b
        cmpa #6
        bls dd_necklp

        ldb dragon_headfrm         ; dragon_headfrm picks 109 or 110, both
        cmpb #110                  ; sharing width/height/bpr -- only the
        beq dd_head110              ; bitmap pointer differs
        ldd #aspr_109_w
        bra dd_headptr
dd_head110
        ldd #aspr_110_w
dd_headptr
        std blit_ptr
        lda #DRAGON_HEAD_X
        sta blit_x
        lda udr_head_y
        sta blit_y
        jsr blit

        lda dragon_fire
        beq dd_done
        lda dragon_flame_n
        beq dd_done
        sta dd_flame_i
        ldx #dragon_flame_x
dd_flamelp
        ldd #aspr_112_mirror      ; T0116: mirrored -- see its definition
        std blit_ptr
        lda ,x+
        sta blit_x
        lda udr_head_y
        adda #8
        sta blit_y
        pshs x
        jsr blit
        puls x
        dec dd_flame_i
        bne dd_flamelp
dd_done
        rts

; T0116: frame 112 (the flame puff) mirrored left-right, each byte
; bit-reversed. The dragon faces LEFT and its plume travels left, and the
; real game draws each puff with its tip leading to the left (filmed in
; MAME). Drawn from frame 112's bytes as extracted, the tips pointed right,
; back at the dragon, so the plume read as being sucked INTO the mouth even
; though the puffs were moving outward. Header shape matches every sprite:
; (w,h,bpr) then bitmap. Collision still reads aspr_112_w/h (same size).
aspr_112_mirror fcb 8,8,1
        fcb $02,$06,$2d,$2a,$5f,$ee,$14,$02

; dragon_necky: B = segment number (1..6) -> A = -(B*dragon_swing/8),
; signed -- i.e. exactly the amount the CALLER adds to DRAGON_ORIGY,
; sparing it a separate subtract. X-ALL.TXT's `findnecky`, minus the
; b=0 special case (never called that way here). 6809's MUL is
; unsigned, so a negative swing is negated, multiplied, shifted, and
; the negation folded into whichever branch needs it to end up with
; the right final sign.
dragon_necky
        lda dragon_swing
        bpl dn_pos
        nega                      ; A = |swing|
        mul                       ; D = B * |swing|  (max 6*8=48, fits B)
        lsrb
        lsrb
        lsrb                      ; B = |swing|*b / 8 (already the sign
        tfr b,a                   ; the caller wants: swing<0 means the
        rts                       ; segment moves DOWN, i.e. + origy)
dn_pos
        mul                       ; D = B * swing  (max 6*16=96, fits B)
        lsrb
        lsrb
        lsrb
        negb                      ; swing>=0: caller wants - origy
        tfr b,a
        rts

dd_rows     fcb 0
dd_flame_i  fcb 0
dd_b        fcb 0
dragon_neck_x fcb 176,172,168,164,160,156

; --------------------------------------------------------------------
; --------------------------------------------------------------------
; clear_and_blit: clear the box at (cb_x,cb_y) sized per cb_spr's own
; header, then blit cb_spr there. Factored out because draw_flames and
; draw_actors were three near-identical copies of the same ~35-
; instruction clear+blit loop -- real, measured cost under a byte
; budget that's critically tight below the framebuffer (see NOTES.md
; "headroom" notes) -- and it's what makes T0032's water animation
; cheap to add instead of a fourth copy.
; --------------------------------------------------------------------
; --------------------------------------------------------------------
; cb_needed: should the sprite at (cb_x,cb_y) sized per cb_spr actually
; be redrawn into this buffer? Z clear = yes.
;
; Measured (MAME, emulated-time, host-independent): drawing the 6 flame
; sprites -- 2 torches + room 2's 4-tile fire pit -- unconditionally
; every pass cost 41% of the entire frame budget, taking the port from
; ~13.8 to ~9.8 passes/sec. But the flame ANIMATION only advances every
; ANIM_DIVIDER (4) passes, so three of every four of those redraws
; painted identical pixels in identical places. This test skips those:
; redraw only when the animation variant actually changed for THIS
; buffer (tracked per buffer, since the two alternate and each needs
; its own copy), or when Dizzy's damage rect overlapped the sprite and
; therefore erased part of it, or on a full-invalidation pass (where
; redraw sets the damage rect to the whole screen, so the overlap test
; passes naturally).
; --------------------------------------------------------------------
cb_needed
        tst cb_force
        bne cbn_yes

        ; AABB against the current damage rect, same test rd_placelp and
        ; draw_actors already use.
        ldu cb_spr
        lda cb_x
        lsra
        lsra
        lsra
        sta cb_col0
        ldb 2,u                  ; bytes per row
        addb cb_col0
        incb                     ; +1 for the 4px-shifted spill
        stb cb_col1
        lda cb_y
        sta cb_ry0
        ldb 1,u                  ; height
        addb cb_ry0
        stb cb_ry1

        lda cb_col0
        cmpa dmg_col1
        bhs cbn_no
        lda dmg_col0
        cmpa cb_col1
        bhs cbn_no
        lda cb_ry0
        cmpa dmg_y1
        bhs cbn_no
        lda dmg_y0
        cmpa cb_ry1
        bhs cbn_no
cbn_yes
        lda #1
        rts
cbn_no
        clra
        rts

; --------------------------------------------------------------------
; blit_only: the tail of clear_and_blit, factored out (T0063) so a
; caller that does NOT want the pre-clear can reach it directly. cb_spr/
; cb_x/cb_y must already be set. See clear_and_blit's own header for
; which callers need the clear and which don't.
; --------------------------------------------------------------------
blit_only
        ldd cb_spr
        std blit_ptr
        lda cb_x
        sta blit_x
        lda cb_y
        sta blit_y
        jmp blit                 ; tail call: blit's own rts returns to our caller

; --------------------------------------------------------------------
; clear_and_blit: black-fill the sprite's own bounding box, THEN blit
; its ink on top.
;
; T0063: this is the RIGHT thing for anything whose drawn content can
; change while its box stays put -- the animated flame/water tiles
; (different frame every cycle) and the crocodile (frame 123/124
; toggling in place) -- because `blit` only ever ORs ink in, so the
; PREVIOUS frame's ink has to be erased first or it leaks forward
; forever, merging with whatever comes next.
;
; It is the WRONG thing for a static, never-reanimating actor sitting
; on top of already-drawn room art -- a dropped loaf on the floor, the
; apple on its table, the jug, the railing. By the time draw_actors
; runs, redraw_placements_dmg has ALREADY restored the real floor/wall
; art under the actor's box this same pass; clearing again wipes that
; back to black everywhere the actor's OWN sprite has no ink (a round
; loaf against a square bounding box, say), and nothing ever repaints
; it -- unlike the rat's save-under, THIS clear has no "restore what I
; erased" step. Real playtest: "if I drop the bread, it is drawn over a
; black background... draw the object over the scene". draw_actors now
; routes ROU_PICKUPABLE straight to blit_only instead, skipping this.
; --------------------------------------------------------------------
clear_and_blit
        ; T0064: the row address and the clear width are LOOP-INVARIANT
        ; and used to be recomputed for every single row -- a `mul`, a
        ; reload of cb_spr, a re-derivation of cb_x's byte column and of
        ; the shifted-width adjustment, ~70 cycles of it, to clear two or
        ; three bytes. Measured on the fire pit's four tiles, which are
        ; the most expensive thing in room 36's frame: they redraw every
        ; pass (they sit at floor height, exactly where Dizzy's damage
        ; rect keeps landing), so this ran 13 rows x 4 tiles x every
        ; frame. Now computed once, with X walked forward by a
        ; precomputed stride, the same shape T0052 gave `blit` itself.
        ldu cb_spr
        ldb 1,u                  ; height
        stb cb_rows

        ; T0067: same vertical clip as blit -- this loop walks rows off
        ; the bottom of the framebuffer just as happily.
        ldb #192
        tst fb_flip              ; T0125: flipped window ends at 184, and a
        beq cab_bot              ; box starting above it skips the clear
        lda cb_y                 ; (rows < 40 would mirror past row 191);
        cmpa win_top             ; blit clips its own top
        blo blit_only
        ldb #FLIP_YEND
cab_bot
        stb cb_ybot
        lda cb_y
        cmpa cb_ybot
        bhs cab_offscreen
        adda cb_rows
        cmpa cb_ybot
        bls cab_rowsok
        lda cb_ybot
        suba cb_y
        sta cb_rows
cab_rowsok

        ; clear width, ONCE.
        ldb 2,u                  ; bytes per row
        ; T0056: the +1 is ONLY for a 4px-shifted sprite, which really
        ; does spill into the next byte. An ALIGNED one does not, and
        ; clearing that extra byte anyway wipes 8px of whatever sits
        ; immediately to its right -- with nothing to repaint it, since
        ; this clear (unlike the rat's save-under) never restores the
        ; static art underneath. Reported as room 52's removable railing
        ; section looking "not aligned with the others": it is at exactly
        ; the right x, but drawing it erased the left half of the fixed
        ; railing beside it.
        lda cb_x
        anda #$04
        beq cab_widthok
        incb
cab_widthok
        stb cb_width

        ; first row's first byte, ONCE.
        ldb cb_y
        jsr fb_rowd              ; T0125: row 231-y when flipped
        tfr d,x
        lda cb_x
        lsra
        lsra
        lsra
        tfr a,b
        abx

        ; per-row advance: the inner loop leaves X exactly cb_width along
        ldb #FBWIDTH
        subb cb_width
        jsr fb_strideb           ; T0125
        stb cb_stride
        clra                     ; the byte being written, held across rows
cab_clrrow
        ldb cb_width
cab_clrcell
        sta ,x+
        decb
        bne cab_clrcell
        ldb cb_stride
        leax b,x                 ; T0125: signed
        dec cb_rows
        bne cab_clrrow

        jmp blit_only             ; tail call: blit_only's blit rts returns to our caller
cab_offscreen
        rts

; --------------------------------------------------------------------
; rat_clear_and_blit: like clear_and_blit, but clears the UNION of the
; rat's last-drawn x IN THIS BUFFER and its current x, not just where
; it's about to be drawn.
;
; The rat moves under its own power every pass, entirely outside
; Dizzy's own damage rect -- clear_and_blit's "clear only where I'm
; about to draw" left every previous frame's footprint un-erased
; (`blit` only ever ORs ink in, never removes it), showing up as a
; dot-trail along the whole patrol. Turning around made it worse: the
; mirrored sprite variant has different content at the overlap, so the
; old frame's un-cleared pixels read as a leftover "butt" facing the
; wrong way. Real playtest: "leaving garbage on screen, like a dot
; trail... when it turns around it leaves a rat butt behind".
;
; Same per-buffer "last position" bookkeeping Dizzy's own damage rect
; already uses (bufA_last_x/bufB_last_x, see redraw) -- a second,
; rat-scoped copy, since the rat is the one actor that needs it (every
; other actor is static and uses clear_and_blit's simpler single-spot
; clear via da_clear's sibling path in actors.asm).
; --------------------------------------------------------------------
; T0052: SAVE-UNDER, replacing clear-and-restore-from-the-placement-list.
;
; What this used to do, every single frame: clear the union of the rat's
; old and new positions, then rescan ALL 63 of the room's placements to
; repaint whatever static art lived in that rectangle. Measured at 14% of
; a room-36 frame -- a second full placement scan on top of Dizzy's own,
; plus the blits.
;
; The original never does anything like it. PRTDIZZY.PDS saves the screen
; bytes it is about to cover into `storescreen` and `ruboutdizzy` puts
; them straight back, so a moving sprite costs its own area twice and the
; room art is never consulted at all. That is what this does now.
;
; ORDERING, which is the whole subtlety: the restore happens at the TOP of
; redraw (before the damage-rect clear), not here. If it ran here it would
; repaint the rat's old background over a Dizzy who had since moved into
; that spot, and he would flicker for a frame. Restoring first means the
; buffer is pure static art before anything is drawn into it. The save
; below can therefore capture Dizzy's pixels where the two overlap -- that
; is fine, because the area is inside Dizzy's own damage rect (the union
; of his old and new positions), which repaints it next frame anyway.
rat_clear_and_blit
        jsr rat_save
        ldd cb_spr
        std blit_ptr
        lda cb_x
        sta blit_x
        lda cb_y
        sta blit_y
        jmp blit                 ; tail call: blit's own rts returns to our caller

RAT_SV_W     equ 5      ; 32px sprite = 4 bytes + 1 for the 4px-shift spill
        if TAPE_ROOMS
RAT_SV_H     equ 14     ; T0239: the room-49 hawk shares this save-under (frame 99 is 14 rows)
RAT_SV_CAP   equ 112    ; T0218: Dozy's 24x28 -> 4 bytes x 28 rows; rat_sv_setup sizes each save to its sprite
        else
RAT_SV_H     equ 8      ; tallest rat frame is 7
RAT_SV_CAP   equ RAT_SV_W*RAT_SV_H
        endif

; rat_sv_setup: point X at this frame's screen block and U at the save
; buffer for the buffer being DRAWN INTO (cur_buf==0 means B is the target
; -- see redraw), and work out a width/height clipped to the screen.
rat_sv_setup
        lda cb_x
        lsra
        lsra
        lsra
        sta rat_sv_col
        lda #FBWIDTH
        suba rat_sv_col
        if TAPE_ROOMS
        ; T0218: the save block is the sprite's OWN size (bpr+1 bytes wide,
        ; height rows) instead of the fixed 5x14: room 45's floating Dozy is
        ; 24x28 and a 5x28 block would not fit the $7E00 gap. The most any
        ; user needs is Dozy's 4x28 = 112 (RAT_SV_CAP); hawk 5x14, rat/log 5x7.
        ldu cb_spr
        ldb 2,u
        incb
        stb rat_sv_w
        cmpa rat_sv_w
        bhs rsu_wok              ; near the right edge: use what is left
        sta rat_sv_w
rsu_wok
        else
        cmpa #RAT_SV_W
        bls rsu_wok              ; near the right edge: use what is left
        lda #RAT_SV_W
rsu_wok
        sta rat_sv_w
        endif
        lda #FBWIDTH
        suba rat_sv_w
        sta rat_sv_stride
        if TAPE_ROOMS
        lda 1,u
        else
        lda #RAT_SV_H
        endif
        sta rat_sv_h

        lda #FBWIDTH
        ldb cb_y
        mul
        addd draw_base
        tfr d,x
        ldb rat_sv_col
        abx
        rts

rat_sv_slot                      ; U -> this buffer's 4-byte header
        lda cur_buf
        bne rss_a
        ldu #rat_sv_hdr_b
        rts
rss_a
        ldu #rat_sv_hdr_a
        rts

rat_save
        jsr rat_sv_setup
        pshs x                   ; screen address
        jsr rat_sv_slot
        puls x
        stx 1,u                  ; header: addr
        lda rat_sv_w
        sta 3,u
        lda rat_sv_h
        sta 4,u
        lda #1
        sta ,u                   ; valid
        leau 5,u                 ; U -> this buffer's byte store
        lda rat_sv_h
        sta rat_sv_rows
rsv_row
        ldb rat_sv_w
rsv_byte
        lda ,x+
        sta ,u+
        decb
        bne rsv_byte
        ldb rat_sv_stride
        abx
        dec rat_sv_rows
        bne rsv_row
        rts

; rat_restore: called from redraw BEFORE anything is drawn into the buffer.
rat_restore
        jsr rat_sv_slot
        lda ,u
        beq rre_done             ; nothing saved for this buffer yet
        ldx 1,u
        lda 3,u
        sta rat_sv_w
        lda #FBWIDTH
        suba rat_sv_w
        sta rat_sv_stride
        lda 4,u
        sta rat_sv_rows
        leau 5,u
rre_row
        ldb rat_sv_w
rre_byte
        lda ,u+
        sta ,x+
        decb
        bne rre_byte
        ldb rat_sv_stride
        abx
        dec rat_sv_rows
        bne rre_row
rre_done
        rts

; force_redraw (T0221): the "repaint both buffers whole next frame" idiom,
; which appeared verbatim at 22 sites across six files -- 8 bytes each of
; `lda #255 / sta bufA_last_x / sta bufB_last_x`. As a call it is 3, and the
; substitution is exact: the routine leaves A=255 and the same CC flags the
; inline `lda #255` did, so any site that went on to use either is unaffected.
; 255 is the "this buffer's contents are unknown" sentinel redraw tests.
force_redraw
        lda #255
        sta bufA_last_x
        sta bufB_last_x
        rts

; rat_sv_invalidate: after a full-screen repaint the saved bytes describe
; a screen that no longer exists, so drop them.
rat_sv_invalidate
        jsr rat_sv_slot
        clr ,u
        ; T0214: every OTHER per-buffer "what did I last draw here" cache
        ; needs dropping here for the very same reason, and none of them
        ; ever was. draw_flames/draw_fire compare the current animation
        ; variant against their record for THIS buffer and skip the
        ; clear+blit when it matches -- so after a full repaint (a new
        ; game, a game-over restart, any room change) the record says
        ; "already drawn" about a screen that was just wiped, and the
        ; flames are never drawn onto it at all. Playtest: "when the game
        ; resets not everything on the rooms resets, like the fire on the
        ; first room".
        ;
        ; flame_var_a/b and fire_var_a/b are FOUR ADJACENT bytes (check the .map),
        ; so two 16-bit stores cover all of them. 255 is the "never drawn in
        ; this buffer" value they already use.
        ldd #$ffff
        std flame_var_a
        std fire_var_a
        ; T0215: the other two, funded by T0219's dead-code removal.
        ; rat_lastx_a/b (adjacent) is the rat's last DRAWN x per buffer and
        ; gate_last_a/b (adjacent) is draw_gate's -- both 255 = "never drawn
        ; in this buffer", both never invalidated, so after a full repaint
        ; each restores or skips against a position that is no longer on
        ; screen. Playtest: "odd flickers and eventually crashes after
        ; restarting from a game over".
        std rat_lastx_a
        std gate_last_a
        rts

; wait_vsync: blocks until the next ~60Hz vertical-sync-derived pulse
; on PIA0 side B (Inman & Inman ch.7 "Interrupts", p.159 -- $FF02/$FF03
; is a 60Hz clock; bit7 of the control register $FF03 sets on each
; pulse, cleared by reading the data register $FF02). Polled, not a
; real interrupt handler -- IRQ/FIRQ stay globally disabled (orcc #$50
; at program start) same as everywhere else in this file; the pulse
; flag itself is set by hardware regardless of whether the CPU is
; masked from jumping to it automatically, so polling doesn't need
; interrupts re-enabled. Doesn't touch $FF00/$FF02 as DATA registers
; the way scankeys does -- different register ($FF03, the control
; register) for the enable/poll, and reading $FF02 here only to clear
; the flag, which doesn't disturb whatever column-select value
; scankeys last wrote there.
; --------------------------------------------------------------------
; --------------------------------------------------------------------
; T0051 frame pacing. `field_ctr` counts 60Hz field boundaries since the
; last page flip, so `redraw`'s tail can hold a frame until a FIXED
; number of fields have passed and every scene runs at the same speed.
;
; The problem it solves, measured rather than assumed: room 36 ran at
; 10.5 mainloop passes/sec with the fireplace lit and 15.6 with it out
; -- a 48% speed-up from one scene detail, reported from real play as
; "everything speeds up as soon as the fire is out". There was no real
; pacing before: `wait_vsync` returns IMMEDIATELY when the PIA's pulse
; flag is already latched, which it always is once a frame's work has
; overrun one field, so the loop simply free-ran at whatever rate the
; scene's own cost allowed.
;
; The flag is a single latch, not a counter, so a field boundary that
; passes mid-frame is indistinguishable from ten. `tick_poll` is
; therefore called from inside the frame's own long-running loops (the
; damage-rect clear, the placement scan, and `blit` itself) so each
; boundary is consumed and counted as it happens. Cost is ~14 cycles a
; call against a field's ~15000, and the calls only need to be closer
; together than one field for the count to stay exact.
;
; This is the original's own approach, not an invention: X-ALL.TXT's
; main loop waits on `clock`, a counter its 50Hz interrupt drives, for
; 3 ticks -- 16.7 updates/sec, scene-independent. This port can't use an
; interrupt for it (IRQs stay masked, and in all-RAM mode the vector
; area at $FFF0 is uninitialised RAM -- see start:), so it polls.
tick_poll
        lda $ff03
        bpl tp_none              ; no field boundary pending
        lda $ff02                ; consume it (reading side B clears CB1)
        inc field_ctr
tp_none
        rts

wait_vsync
        lda $ff03
        bpl wait_vsync
        lda $ff02       ; clear the pulse flag
        inc field_ctr
        rts

; --------------------------------------------------------------------
; rng_step: advance rng_ctr by one step of an 8-bit Galois LFSR (taps
; 0xB8, i.e. x^8+x^6+x^5+x^4+1 -- a standard maximal-length polynomial:
; every nonzero seed cycles through all 255 nonzero byte values before
; repeating). Called once per mainloop pass to feed rat_newdir's leg
; timing -- see that routine's own comment for why a plain incrementing
; counter is provably wrong here (it collapses to a fixed point via a
; doubling-map correlation with its own call cadence), not merely low
; quality. An LFSR's linear-over-GF(2) recurrence doesn't have that
; closed-form collapse.
;
; State 0 is the one seed an LFSR can never leave (0 -> 0 forever), so
; reseed to 1 if that's ever reached -- rng_ctr's own storage starts at
; 0 (fcb 0), which would otherwise wedge the whole generator before its
; first real call.
; --------------------------------------------------------------------
rng_step
        lda rng_ctr
        bne rs_have_seed
        lda #1
        bra rs_store
rs_have_seed
        lsra
        bcc rs_store
        eora #$B8
rs_store
        sta rng_ctr
        rts

; --------------------------------------------------------------------
; Collision probes against room_cmask (64x48 grid of 4x4-pixel blocks,
; 8 bytes per row, bit set = solid). See the constants block at the top
; for where the mask comes from and why bit 6 of the room colour byte
; decides solidity.
;
; cmask_test: probe_x/probe_y (pixel coords) -> Z clear if that pixel's
; block is solid. Caller must keep coords on-screen; the routine does no
; range checking of its own (the callers all clamp first).
; --------------------------------------------------------------------
cmask_test
        lda probe_y              ; T0187: probe_y IS the row (0-191)
        ldb #CM_STRIDE
        mul                      ; D = row * 8
        addd #CUR_ROOM_CMASK     ; T0166: CUR_ROOM_CMASK is fixed now --
                                   ; no per-room pointer to add, derive_
                                   ; room_cmask always fills it in place
        tfr d,x
        lda probe_x
        lsra
        lsra                     ; A = block col (0-63)
        pshs a
        lsra
        lsra
        lsra                     ; A = col >> 3 = byte within the row
        tfr a,b
        abx
        puls a
        anda #7                  ; A = bit within that byte
        ldy #cm_bittab
        lda a,y
        anda ,x                  ; Z clear = solid
        bne ct_solid
        ; T0103: the scenery mask says no -- now ask the ACTORS.
        ;
        ; The original has no collision mask and no scenery-vs-actor
        ; distinction: checkattri reads the attribute off the SCREEN, and
        ; a drawn actor paints its own colour byte there. So any actor
        ; whose colour has bit 6 clear is solid, for free, with no code.
        ; This port precomputes a static scenery mask, so until now no
        ; actor was ever collidable -- which is why the gator had no nose
        ; to land on and the portcullis blocked nothing.
        ;
        ; Hooked in cmask_test because that is the single choke point
        ; every probe goes through, floor and wall alike, so actors
        ; become solid everywhere at once rather than in one hand-picked
        ; check.
        lbra actor_solid_test     ; (long: T0124's lift entry in build_solid_actors put it out of range)
ct_solid
        rts


; build_solid_actors: collect this room's solid actors once per pass.
;
; Scanning all 20 actor slots INSIDE cmask_test cost room 36 nearly a
; fifth of its frame rate (15.0 -> 12.2 passes/sec): cmask_test has ten
; call sites and the floor search walks downward through it, so the scan
; ran far more often than "once per probe". Precomputing the short list
; here makes the common case -- a room with no solid actors -- a single
; byte test.
SOLID_MAX equ 4
build_solid_actors
        clr n_solid
        if TAPE_ROOMS
        clr bsa_tape_phase
        endif
        ldy #actor_ram
        ldx #solid_list
        lda #ACTOR_COUNT
        sta bsa_n
bsa_loop
        lda ,y                   ; room
        cmpa cur_room
        lbne bsa_next
        lda 7,y                  ; colour: bit 6 "dull" = decorative
        anda #$40
        lbne bsa_next
        lda n_solid
        cmpa #SOLID_MAX
        lbeq bsa_done

        ; T0115: the portcullis collides as the lattice column it is on
        ; screen (draw_gate): from PORT_OPEN_Y down to its current y plus
        ; the sprite's six inked rows -- 46 rows when closed at rest, 6
        ; when fully open. In the original, collision reads the screen's
        ; attributes, so the drawn column is exactly what is solid.
        ; gate_col_hdr is a synthetic full-ink sprite; its height byte is
        ; rewritten here every pass.
        lda 1,y                  ; routine
        cmpa #ROU_PORTCULLIS
        bne bsa_normal
        lda 3,y
        suba #PORT_OPEN_Y-6      ; height = y - 96 + 6
        sta gate_col_hdr+1
        lda 2,y                  ; x (unchanged -- same column)
        sta ,x+
        lda #PORT_OPEN_Y         ; y: pinned to the top of the column,
        sta ,x+                  ; regardless of where the sprite is now
        ldu #gate_col_hdr
        stu ,x++
        inc n_solid
        bra bsa_next
bsa_normal
        ; T0124: a lift is two solid parts -- its top (frame 125, the normal
        ; entry below) and the bar Dizzy rides, frame 126, 40px lower.
        lda 1,y
        cmpa #ROU_LIFT
        bne bsa_notlift
        ; T0137: and its rope. X-ALL.TXT resetrope stamps frame 125 every 2
        ; rows from origy down to the lift, so the hook's ink forms a rope
        ; column on screen, and collision reads the screen: it is solid. The
        ; 2px rope (draw_lift: px col*8+15/16) spans two 4px nibbles, which
        ; is exactly an 8px box at col*8+12 under actor_solid_test.
        lda cur_room
        jsr ul_bounds             ; ul_orig = the rope's top row
        lda 3,y
        suba ul_orig
        bls bsa_norope            ; lift at its start height: no rope
        sta rope_col_hdr+1
        lda 2,y
        anda #$f8
        adda #12
        sta ,x+
        lda ul_orig
        sta ,x+
        ldu #rope_col_hdr
        stu ,x++
        inc n_solid
        lda n_solid
        cmpa #SOLID_MAX
        beq bsa_done
bsa_norope
        lda 2,y
        sta ,x+
        lda 3,y
        adda #40
        sta ,x+
        ldu #aspr_126_w
        stu ,x++
        inc n_solid
        lda n_solid
        cmpa #SOLID_MAX
        beq bsa_done
bsa_notlift
        pshs x
        jsr actor_sprite_for     ; the sprite that will actually be DRAWN
        puls x
        cmpu #0
        beq bsa_next
        lda 2,y                  ; x
        sta ,x+
        lda 3,y                  ; y
        sta ,x+
        stu ,x++
        inc n_solid
bsa_next
        leay ACTOR_STRIDE,y
        dec bsa_n
        lbne bsa_loop
bsa_done
        if TAPE_ROOMS
; T0238: rooms 40/88/94's lift (and rope/bar) solid bodies live in
; actor_init_tape -- a second pass through the SAME bsa_loop body
; (n_solid/solid_list/x are already threaded through correctly; only
; the table base+count differ, same shape as ul_scan_tbl above).
; bsa_tape_phase stops this second pass re-entering itself once IT
; also exhausts (the SOLID_MAX cap can send either pass here early).
        tst bsa_tape_phase
        bne bsa_done2
        inc bsa_tape_phase
        ldy #actor_init_tape
        lda #ACTOR_COUNT_tape
        sta bsa_n
        lbra bsa_loop
bsa_done2
        endif
        rts

; actor_solid_test: probe_x/probe_y against this room's solid actors.
; Z clear = solid, matching cmask_test's contract.
;
; The original has no collision mask and no scenery-vs-actor distinction:
; checkattri reads the attribute off the SCREEN, and a drawn actor paints
; its own colour there. Ink is tested too, not just the bounding box --
; checkattri only runs when the pixel byte is non-zero, and box-only left
; Dizzy standing in mid-air on the gator's empty top-left corner.
actor_solid_test
        lda n_solid
        bne ast_scan
        clra                     ; nothing solid here -- the common case
        rts
ast_scan
        pshs u,y
        sta ast_n
        ldy #solid_list
ast_loop
        sty ast_cur
        ldu 2,y                  ; sprite header (w,h,bpr)
        lda probe_y
        suba 1,y                 ; - actor y
        blo ast_next             ; above it
        cmpa 1,u                 ; height
        bhs ast_next             ; below it
        ldb 2,u                  ; bytes per row
        mul                      ; D = row * bpr
        leax d,u
        leax 3,x                 ; past the (w,h,bpr) header
        ; T0137: the original reads the screen a NIBBLE at a time -- the
        ; Spectrum getbyte masks 11110000b/00001111b by lookx parity, and
        ; lookx is a 4px unit -- so a probe is solid when ANY ink falls in
        ; its 4px screen column. Testing the single pixel missed room 71's
        ; lift top, whose only ink under Dizzy's feet is a 2px hook.
        ;
        ; ONE masked test, not a four-column loop: every actor x is a
        ; multiple of 4 (they all come from the source's own 4px units),
        ; and probe_x is masked down to its column, so the four pixels
        ; never straddle a byte -- they are exactly the high or the low
        ; nibble. The loop version cost enough time in this, the hottest
        ; collision path, to shift harness timing (it broke tiecroc).
        lda probe_x
        anda #$fc                ; the column's first screen pixel
        suba ,y                  ; - actor x (wraps >= width when left of it)
        cmpa ,u                  ; width (all sprites < 128 wide)
        bhs ast_next
        tst 2,u                  ; bpr 0: a synthetic full-ink box (gate
        beq ast_hit              ; column, lift rope) -- no bitmap
        sta ast_col
        lsra
        lsra
        lsra                     ; byte within the row
        tfr a,b
        abx                      ; X = the row byte holding this column
        lda ast_col
        anda #4                  ; which nibble of it
        beq ast_hinib
        lda #$0f
        bra ast_nibmask
ast_hinib
        lda #$f0
ast_nibmask
        anda ,x                  ; Z clear = ink somewhere in the 4px column
        beq ast_next
ast_hit
        puls u,y
        lda #1                   ; Z clear = solid
        rts
ast_next
        ldy ast_cur
        leay 4,y
        dec ast_n
        bne ast_loop
        puls u,y
        clra                     ; Z set = not solid
        rts

ast_n      fcb 0
ast_col    fcb 0
ast_cur    fdb 0
bsa_n      fcb 0
n_solid    fcb 0
        if TAPE_ROOMS
bsa_tape_phase fcb 0
        endif
solid_list rmb SOLID_MAX*4       ; x, y, sprite-header ptr

; --------------------------------------------------------------------
; T0142: blit_mkrev -- build blit_revbuf as this source row, mirrored.
;
; Every sprite width here is a multiple of 8 (checked across all 226),
; so a horizontal flip is exactly "reverse the byte order, reverse the
; bits in each byte" with no bit-shift to fix up. The bit reversal is two
; 16-byte nibble tables rather than one 256-byte table: rev_hi[low] is
; rev4(low)<<4 and rev_lo[high] is rev4(high), so a byte costs two
; lookups and no shifting loop. Y holds nibswap+128 for the caller, so it
; is saved here.
; --------------------------------------------------------------------
blit_mkrev
        pshs a,b,x,y,u
        ldb blit_bpr
        stb bmr_n
        leau b,u
        leau -1,u                ; U -> last byte of the row
        ldx #blit_revbuf
        ldy #rev_lo              ; ONE table: the high-nibble variant costs
bmr_lp                            ; 16 bytes, four shifts cost four
        lda ,u
        pshs a
        anda #$0f                ; low nibble -> becomes the high one
        lda a,y
        lsla
        lsla
        lsla
        lsla
        sta ,x
        puls a
        lsra
        lsra
        lsra
        lsra                     ; high nibble -> becomes the low one
        lda a,y
        ora ,x
        sta ,x+
        leau -1,u
        dec bmr_n
        bne bmr_lp
        puls a,b,x,y,u
        rts

rev_lo  fcb $00,$08,$04,$0c,$02,$0a,$06,$0e,$01,$09,$05,$0d,$03,$0b,$07,$0f
blit_mirror fcb 0                ; set by a caller for the NEXT blit only
bm_cur      fcb 0                ; latched for the blit in progress
bmr_n       fcb 0
blit_revbuf rmb 10               ; max bpr across every sprite is 10

; T0102: synthetic full-ink column, (PORT_CLOSED_Y-PORT_OPEN_Y)+8=48 rows
; tall, 8px wide -- a FILLED portcullis collides against this instead of
; its own 8x8 sprite. Header shape matches every real sprite, (w,h,bpr);
; T0137: bpr 0 tells actor_solid_test "every bit set" so no bitmap follows.
gate_col_hdr fcb 8,48,0
; T0137: the lift's rope, the same kind of box. h is rewritten every pass.
rope_col_hdr fcb 8,0,0

cm_bittab
        fcb $80,$40,$20,$10,$08,$04,$02,$01

; --------------------------------------------------------------------
; T0088/T0089: play_tone -- blocking square-wave tone on the 6-bit DAC.
;
; On entry: X = pt_period (half-wave delay, PITCH, 16-bit), B =
; pt_count (number of half-waves, DURATION -- 2 half-waves is one full
; cycle, 1 byte, max 255). Toggles $FF20 bit 6 each half-wave -- bits
; 7-2 are the DAC's 6-bit value, bit 6 alone gives a clean centred
; square wave with no need to compute a specific amplitude level.
;
; T0089 widened pt_period from 8 to 16 bits: the real captured AY music
; (tools/aycapture, from the original's MUSIC128.SPC -- see NOTES.md,
; the 48K build has its OWN real tunes/sfx too, MUSIC48.SPC, this port
; captures the 128K ones per the explicit request to prefer them) is
; 90%+ notes below ~340Hz, the floor an 8-bit delay count could reach --
; at 8 bits EVERY bass note clamped to the same value and the reduction
; collapsed whole basslines into one flat drone.
;
; COST MODEL -- hand-derived from THIS loop and measured, agreeing to 1%:
;   lda pt_level 5 / eora pt_amp 5 / sta pt_level 5 / sta $ff20 5 / ldx 6
;   + (leax 5 + bne 3) x period + dec pt_count 7 + bne 3
;   = 36 + 8*period per HALF wave  ->  72 + 16*period per FULL wave
; (was 33/66 with `eora #$40`; per-note amplitude made the toggle an
; extended-mode eora, +3 cycles -- re-measured: 69.5Hz at period 800)
; harness/tonecal.asm swept 7 points, 18Hz to 531Hz, and least-squares
; fitted 16.11*period + 62 against the 16.00*period + 66 derived above (for the pre-amplitude loop).
;
;     period_for_hz(f) = round((894780/f - 72) / 16)
;
; DO NOT re-derive this with `audiocheck.py --scan`. T0089 first did
; exactly that and shipped `(894780/f - 1164)/21.1`: --scan read the
; pitch of these very same captures 25-34% LOW, by an amount that VARIED
; with frequency, so notes played 6-40 semitones sharp with every melodic
; interval stretched -- and, because half-wave counts are computed for
; the INTENDED frequency, every note came out too short as well. A
; playtest caught it in seconds. Nothing automated here did: amplitude
; was healthy, rate.lua was clean, the pickup test passed. NOTES.md had
; already recorded that --scan's pitch reading is untrustworthy; that
; warning was written about short blips and got applied to a sustained
; tone anyway. Sustained tone + audiocheck.py's DEFAULT tail window,
; cross-checked against the cycle counts above, is the trusted method.
;
; NOT continuous music, and NOT free even for a short blip: cost is
; dominated by PERIOD, i.e. by how LOW the note is -- a single half-wave
; at ~70Hz is still ~7ms. room36 already spends ~47ms of a
; 66.7ms frame (NOTES.md); a scripted pickup test that walks into an
; item caught a real regression from this -- a ~7ms footstep click on
; EVERY step was enough to make Dizzy visibly undershoot, and a ~1.3s
; new-life tune fired mid-respawn silently ran the clock out on a
; scripted key-press window entirely. Both are why callers below gate
; or cap what they play instead of using captured durations verbatim --
; see each routine's own comment for the specific number and how it was
; checked (a rebuilt binary against that same scripted test, not
; assumed safe from the byte count alone).
; --------------------------------------------------------------------
play_tone
        stx pt_period
        stb pt_count
        ; NOTE: deliberately does NOT reset pt_level. A long note is
        ; emitted as several consecutive entries of the same pitch (see
        ; SPLIT_MS in tools/aycapture/reduce), and resetting the phase at
        ; every chunk boundary would put a glitch in the middle of a held
        ; note. Carrying the level over makes the split inaudible.
pt_wave
        lda pt_level
        eora pt_amp              ; toggles between 0 and this note's amplitude
        sta pt_level
        sta $ff20
        ldx pt_period
pt_delaylp
        leax -1,x
        bne pt_delaylp
        dec pt_count
        bne pt_wave
        rts

pt_period fdb 0
pt_count  fcb 0
pt_level  fcb 0
pt_amp    fcb $40            ; set per entry by pt_step

; pt_rest: burn B x ~1ms WITHOUT touching the DAC -- a real rest.
; A tune's rests are not cosmetic: dropping them (T0089's first pass did)
; runs every note together and destroys the rhythm, which is half of why
; the title tune came back from a playtest as "not right".
;   3 (ldx imm) + 8*111 (leax+bne) + 2 (decb) + 3 (bne) = 896 cycles
;   896 / 894780 Hz = 1.0014 ms per unit.
pt_rest
        pshs x
        clr pt_level             ; park the DAC at 0 so a rest is real
        clra                     ; silence, not a half-scale DC level
        sta $ff20                ; held over from wherever the wave stopped
pr_unit
        ldx #111
pr_in   leax -1,x
        bne pr_in
        decb
        bne pr_unit
        puls x
        rts

; play_noise (T0111): B steps of pseudo-random DAC output at pt_amp, X =
; per-step delay. The AY's noise generator has no tone to reduce -- fx10,
; the dragon's breath, runs with every tone bit off -- so it gets its own
; entry type. Its OWN 8-bit Galois LFSR ($B8 taps, period 255), not
; rng_step: that one paces the rat, and harness/rate.lua counts mainloop
; passes by watching it change.
;   high step: lda 5 lsra 2 bcc 3 eora 2 sta 5 lda 5 bra 3 / sta $ff20 5
;              ldx 6 (leax 5 + bne 3)*X dec 7 bne 3  =  46 + 8X cycles
;   low step:  lda 5 lsra 2 bcc 3 sta 5 clra 2 / sta 5 ldx 6 ... = 38 + 8X
; tools/aycapture/reduce budgets the average, 42 + 8X.
play_noise
        stx pt_period
        stb pt_count
pn_step
        lda pn_lfsr
        lsra
        bcc pn_lo
        eora #$b8
        sta pn_lfsr
        lda pt_amp
        bra pn_out
pn_lo
        sta pn_lfsr
        clra
pn_out
        sta $ff20
        ldx pt_period
pn_delay
        leax -1,x
        bne pn_delay
        dec pt_count
        bne pn_step
        clra                     ; park the DAC low, and tell the next tone's
        sta $ff20                ; phase logic the wave is in its low half
        clr pt_level
        rts

pn_lfsr fcb $a5                  ; any non-zero seed

; pt_step: play the ONE table entry at Y and advance Y past it.
; Returns Z SET (beq) when Y was sitting on the terminator, having
; played nothing -- so `jsr pt_step / bne loop` walks a whole table.
; Both play_tune and the title screen's own loop go through this, so
; the two cannot drift apart on the entry format.
;
; Entry format (tools/aycapture/reduce emits it directly):
;   word $0000 -> end of table
;   word $FFFF -> rest, count byte = ~1ms units
;   otherwise  -> note: top nibble = amplitude index 0-15, low 12 bits =
;                 period; count byte = half-waves
;
; AMPLITUDE: the original AY melody moves through 7 volume levels as its
; notes attack and decay. Every note here used to play at one fixed
; amplitude -- the notes and rhythm were measured correct (0.08 semitones
; median, no drift) and the playtest still called it terrible, because a
; constant-level square wave is a blare, not a tune. The index is mapped
; from the AY's logarithmic volume on the host, so the dynamics survive.
; Packed into the period word because every real period fits in 12 bits
; (the lowest note anywhere is ~62Hz = period 894), which keeps entries
; at 3 bytes instead of growing every table by a third.
pt_step
        ldd 0,y
        beq pts_end              ; terminator: Z stays set from the ldd
        cmpd #$ffff
        beq pts_rest
        pshs a
        anda #$0f                ; low 12 bits: period
        std pt_period
        puls a
        anda #$f0                ; high nibble: amplitude index x16 ...
        lsra                     ; ... x8, so full volume is $78
        sta pt_amp
        ; Keep the wave's phase across entries (see play_tone) but at THIS
        ; entry's amplitude: XORing a new amplitude against a level left
        ; by a different one does not toggle between 0 and the new value.
        tst pt_level
        beq pts_phase
        sta pt_level
pts_phase
        ldb 2,y
        leay 3,y
        lda pt_period            ; T0111: $0Fxx = a NOISE entry. Tone periods
        cmpa #$0f                ; stay below $0F00 (reduce asserts it), so
        beq pts_noise            ; this high byte can only mean noise
        ldx pt_period
        jsr play_tone
        andcc #$fb               ; clear Z: "played something, keep going"
        rts
pts_noise
        clr pt_period            ; X = $00xx: the low byte is the step delay
        ldx pt_period
        jsr play_noise
        andcc #$fb
        rts
pts_rest
        ldb 2,y
        leay 3,y
        jsr pt_rest
        andcc #$fb
pts_end
        rts

; play_tune: blocking playback of a whole table. D on entry is its
; address.
play_tune
        pshs y
        tfr d,y
pt_next
        jsr pt_step
        bne pt_next
        puls y
        rts

; play_chirp: COIN pickup (T0255: it was wired to item pickups) -- the original's own trigger table (X-ALL.TXT,
; NOTES.md T0089) fires TUNE 5 for this (`call starttune` right after
; `call addtocoins`), the same tune5_notes captured below -- the real
; sound, not a placeholder. Capped hard (tools/aycapture's max_ms) to
; ~30ms: this fires mid-gameplay (walking onto an item), not during a
; pause, and the first attempt at the full ~117ms capture caused a
; scripted pickup test to read the item as still there -- the test's
; fixed-frame check landed before the blocking call finished removing
; it, not because the pickup logic was broken.
play_chirp
        ldd #tune5_notes
        jmp play_tune

; play_jump: real captured rising "boing" (X-ALL.TXT sndfx 21). Fires
; once per jump, not per frame, so it can afford more than a footstep --
; capped to keep the whole 10-step sweep audible without turning a jump
; into a long pause (tools/aycapture/reduce's max_halfwaves_per_run,
; not max_ms: shortens every step so the full rising contour survives,
; instead of truncating the sweep's end off).
play_jump
        ldd #fx21_notes
        jmp play_tune

; play_footstep: X-ALL.TXT alternates sndfx 0/1 on consecutive steps
; (`ld a,(animation) / and 3 / srl a / ld (sndfx),a`). Captured sndfx 0
; is a ~68Hz thud -- authentic, but even a single half-wave at that
; pitch costs ~9ms on this delay-loop DAC; sndfx 1 (~365Hz) is cheaper
; (~7ms) and is what shipped until T0260 (below: the thud is back, user decision). Firing EVERY step still measurably slowed
; movement (the same scripted pickup test came up short by several
; pixels with it on, matching pixel-for-pixel with and without the
; jump/chirp hooks disabled, which is what isolated this as the actual
; cause rather than those). Gated to every OTHER step here, and
; RE-VERIFIED against that exact test afterward -- not assumed fixed
; from halving the math alone.
;
; T0118: the every-other-step gate is gone -- the caller now fires this
; from the walk animation's sndfx-1 frames (3 and 7) only, which is
; already one call per 8 animation frames of stride and never in the air.
; T0260 (D3): B = the odd animation frame: bit 1 set (3, 7) = sndfx 1, the tap; clear (1, 5) = sndfx 0, the thud
; (X-ALL: `ld a,(animation) / and 3 / srl a / ld (sndfx),a` -> 0 for animation&3 = 1, 1 for 3).
play_footstep
        ldx #fx1_notes
        bitb #2
        bne pf_go
        ldx #fx0_notes
pf_go   tfr x,d
        jmp play_tune

; T0109: the rest of the original's trigger table (NOTES.md T0089 has the
; full map). Each one preserves D and X -- play_tune only keeps Y -- because
; they are dropped into call sites that were never written expecting a
; subroutine there: msg_begin's callers load X straight after it, and
; kill_dizzy_msg is holding its message pointer in X.
play_boxopen                     ; sndfx 6, X-ALL.TXT drawboxrou
        pshs d,x
        ldd #fx6_notes
        bra sfx_go
play_drop                        ; sndfx 11, dropobject
        pshs d,x
        ldd #fx11_notes
        bra sfx_go
play_killed                      ; sndfx 25, right after `ld (killed),a`
        pshs d,x
        ldd #fx25_notes
        bra sfx_go
play_breath                      ; T0111: sndfx 10, startbreath -- AY noise
        pshs d,x
        ldd #fx10_notes
        bra sfx_go
play_deathtune                   ; tune 2, finishmusic after killedmess
        pshs d,x
        ldd #tune2_notes
sfx_go
        jsr play_tune
        puls d,x,pc

; check_ground: is there solid mask directly under Dizzy's feet?
; dizzy_y IS his feet row, so the block at dizzy_y is what he stands on.
; Three probes across his boots so he doesn't hang in the air off one
; corner pixel, nor fall through a narrow gap he's mostly over.
check_ground
        lda dizzy_y
        cmpa #192
        bhs cg_yes               ; off the bottom: treat as solid
        sta probe_y
        lda dizzy_x
        adda #FOOT_L
        sta probe_x
        jsr cmask_test
        bne cg_yes
        lda dizzy_x
        adda #FOOT_ML
        sta probe_x
        jsr cmask_test
        bne cg_yes
        lda dizzy_x
        adda #FOOT_M
        sta probe_x
        jsr cmask_test
        bne cg_yes
        lda dizzy_x
        adda #FOOT_R
        sta probe_x
        jsr cmask_test
        bne cg_yes
        clra                     ; Z set = nothing under him
        rts
cg_yes
        lda #1                   ; Z clear = grounded
        rts

; check_ceiling: solid mask immediately above his head?
check_ceiling
; T0195: the head row is X-ALL.TXT checktopside's own FIXED `sub 20`, not
; dizzy_h. dizzy_h is the CURRENT FRAME's height and the jump frames are
; SHORTER (dizzy_frame_heights has 14s and 15s), so probing y-dizzy_h-1
; walked the head probe DOWN mid-jump and Dizzy slipped up into a ceiling
; the original is blocked by -- he rose 5px into room 68's table instead
; of gliding under it. The source uses one constant for every frame,
; treating Dizzy as always 21 tall (feet at y, sprite y-20..y, so y-20 IS
; the head-top row).
;
; T0187 measured this as EXACTLY neutral and shelved it -- correctly, at
; the time: with ml_bonk still zeroing dizzy_dy the jump ended on the
; bonking pass, so it made no difference how early the bonk fired. It
; only pays once ml_bonk keeps the arc alive.
EGG_HEAD     equ 21      ; checktopside's own `sub 20` is on the ORIGINAL's y; this port's feet y is that +1 (T0232), so the head ROW is y-21
        lda dizzy_y
        suba #EGG_HEAD
        beq cc_yes
        blo cc_yes               ; already at/through the top
        sta probe_y
        ; T0061: the SAME four columns the floor test uses, because the
        ; source uses one routine (`checkline`) for both -- `checktopside`
        ; and `checkbottomside` each just call it. This probed x+0 and
        ; x+20 instead, the columns `checkleftside`/`checkrightside` use,
        ; which is wrong in both directions at once: it blocks on ink 4px
        ; OUTSIDE the source's ceiling span (so room 36's gap up to room
        ; 52 was 2 whole steps narrower than the original's -- passable
        ; only from x=192-208 where the original allows 188-212) and it
        ; ignores the middle 8px entirely (so a narrow overhang between
        ; his hands is not felt at all).
        lda dizzy_x
        adda #FOOT_L
        sta probe_x
        jsr cmask_test
        bne cc_yes
        lda dizzy_x
        adda #FOOT_ML
        sta probe_x
        jsr cmask_test
        bne cc_yes
        lda dizzy_x
        adda #FOOT_M
        sta probe_x
        jsr cmask_test
        bne cc_yes
        lda dizzy_x
        adda #FOOT_R
        sta probe_x
        jsr cmask_test
        bne cc_yes
        clra
        rts
cc_yes
        lda #1
        rts

; check_wall: would Dizzy's body box collide at try_x?
;
; Probe heights are X-ALL.TXT `checkrightside`/`checkleftside` exactly:
; three probes at y-10, y-14, y-18 (it sets looky = y-10 and subtracts 4
; per iteration, b=3). NOTHING is tested at or near the feet, and that is
; deliberate on the original's part -- it is the other half of the
; step-climbing mechanic. An obstacle shorter than ~10px is invisible to
; this test, so Dizzy walks into it and the vertical pass (see the
; step-up lift in the main loop) stands him on top of it. Anything taller
; blocks him here and must be jumped.
;
; So these two heights and STEP_UP are a matched pair: raise the lowest
; probe and low steps start blocking; lower it and Dizzy stops being able
; to walk up things the original lets him walk up. We had y-8/y-16, which
; is why he could not get past the fireplace without jumping.
check_wall
        ; T0232: the probes are y-11/-15/-19, NOT the 10/14/18 above.  This port's
        ; feet y is the original's y + 1 (the original stands at the row ABOVE the
        ; floor ink, the port ON it), so X-ALL's `y-10/-14/-18` is port y-11/-15/-19.
        ; Measured on the ZX original (room 47 jump right from (88,104) onto the
        ; roof cap at (152,72)): with 10/14/18 the port blocked at x=132 where the
        ; original walks on.  Everything below about "10px of slack" reads +1.
        ; T0082 was REVERTED here -- see NOTES.md. The airborne foot
        ; probe fixed a cosmetic wedge and in exchange made room 35's
        ; required jump (y=112 -> the y=80 pillar top, a full 32px rise
        ; needing rightward travel at the apex) close to impossible: it
        ; shrank the window in which he may move right from ~10px of arc
        ; to ~4px. The 10px of slack below is load-bearing for exactly
        ; that kind of jump, not just for the grounded step-climb.
        lda dizzy_y
        suba #11
        sta probe_y
        jsr cw_pair
        bne cw_yes
        lda dizzy_y
        suba #15
        sta probe_y
        jsr cw_pair
        bne cw_yes
        lda dizzy_y
        suba #19
        sta probe_y
        jsr cw_pair
        bne cw_yes
        clra
        rts
cw_yes
        lda #1
        rts



; T0139: ONE column, the leading edge. X-ALL.TXT's checkleftside samples
; lookx=x only when moving left and checkrightside lookx=x+eggwidth-1 only
; when moving right; testing both sides on every step left a Dizzy whose
; trailing side overlapped a wall unable to walk out of it (84r1: the
; original walks out of the pillar into 85, the port was stuck and climbed).
; Callers set cw_side: BODY_L moving left, BODY_R moving right.
cw_pair
        lda try_x
        adda cw_side
        sta probe_x
        jsr cmask_test
        bne cw_hit
        clra
        rts
cw_hit
        lda #1
        rts
cw_side fcb BODY_R

; --------------------------------------------------------------------
; T0023/T0035: room-to-room transitions. Only the edges this slice
; actually has content for are wired up: room 36's left neighbor is 35
; (roomno-1, X-ALL.TXT goneleft/goneright) and its up neighbor is 52
; (roomno+16, X-ALL.TXT goneup/gonedown -- confirmed against
; extracted/rooms.json: room 52 is named "THE ENTRANCE HALL" and its own
; collision data has a matching gap). Room 36's right neighbor (37),
; room 35's up/down/left, and room 52's own up/left/right are all
; empty/unbuilt in this vertical slice -- deliberately not wired, per
; "vertical slice before breadth" -- so those edges just clamp instead.
;
; load_room: given cur_room, point room_place_count/room_placements_ptr
; (+flame/water) at that room's generated data, and derive its collision
; mask straight into CUR_ROOM_CMASK (T0166 -- no stored mask any more)
; (target/room{36,35,52}_data.asm, tools/roompack -- label prefix
; r36_/r35_/r52_ exists specifically so all three rooms' data can be
; `include`d into one assembly without symbol collisions).
; --------------------------------------------------------------------
; box_reset (T0258, D1): X-ALL roomsetup, which runs on every room entry AND at the close of every message box and
; inventory (windowrou1 / justexitinvent -> resetuproom): breathingfire := 0 (5446, resetdragon 2562), the flames
; and water are re-added at counter 0 and 3 (addtoflame / addtowater, T0255), and resetroommoving runs each room
; actor's reset routine -- the actors that keep state reset themselves when room_load_seq changes (Armorog, hawk, log).
box_reset
        clr dragon_fire
        clr flame_ctr             ; T0255: X-ALL addtoflame/addtowater start every room's flames at counter 0 and its
        lda #3                    ; water at 3 (ld c,0 / ld c,3), so the animation phase on entry is fixed, not whatever
        sta water_ctr             ; the global counters had reached in the last room
        inc room_load_seq         ; T0123: lets per-room actors run their reset once per load
        rts

load_room
        jsr box_reset
        ldx #room_desc_table
lr_scan
        ldu ,x++
        cmpu #0
        beq lr_unknown
        lda ,u                   ; this descriptor's room number
        cmpa cur_room
        bne lr_scan

        leau 1,u                 ; past the room number
        ldy #room_place_count
        ldb #ROOM_DESC_LEN
lr_copy
        lda ,u+
        sta ,y+
        decb
        bne lr_copy

        if TAPE_ROOMS
        ; T0235: per-room LZ pack. room_placements_end shipped as the
        ; sentinel 0 (never a valid ROM address for a real end pointer --
        ; roompack's --pack-room-data) means this room's data arrived
        ; packed: room_placements_ptr, just copied above, actually holds
        ; the address of the room's own LZ blob (room_packed), not a raw
        ; SOURCE-order table. Unpack it into the one shared ROOM_UNPACK_
        ; BUF (sized to the largest packed room, roompack's own assemble-
        ; time guard against ROOM_UNPACK_BUF_LEN), then rebuild every
        ; pointer field below from the counts lr_copy already copied --
        ; BEFORE derive_room_cmask/rd_sortplaces read them, exactly like
        ; the raw path they replace.
        ldd room_placements_end
        bne lr_notpacked
        ldu room_placements_ptr
        ldy #ROOM_UNPACK_BUF
        jsr lz_unpack
        jsr tape_room_hook        ; T0223: room 58 + grown beanstalk: append the room-1 overlay placements
        ldd #ROOM_UNPACK_BUF
        std room_placements_ptr
        ldb room_place_count
        lda #3
        mul                       ; D = place_count*3 (placement record size)
        addd #ROOM_UNPACK_BUF
        std room_placements_end
        std room_flames_ptr       ; flames sit right after placements
        ldb room_flame_count
        lda #2
        mul                       ; D = flame_count*2 (flame record size)
        addd room_flames_ptr
        std room_water_ptr        ; water sits right after flames
lr_notpacked
        endif

        ; T0166 (Change 1, delivery half): no stored mask to unpack any
        ; more -- CUR_ROOM_CMASK is now the LIVE mask, filled directly by
        ; derive_room_cmask below (which clears it first). room_cmask_ptr
        ; is gone from the descriptor entirely; cmask_test now addresses
        ; CUR_ROOM_CMASK as a fixed constant (see its own comment).
        ;
        ; T0163 (Change 1, runtime half): room_placements_ptr/end still
        ; point at the room's SOURCE-order table shipped in ROM at this
        ; point (roompack no longer sorts it) -- exactly the order both
        ; of the next two steps need to read it in, and BOTH must finish
        ; reading it before it's repointed below.
        ;
        ; 1. derive_room_cmask: rebuild the mask from placements straight
        ;    into CUR_ROOM_CMASK, then patch in the handful of cells
        ;    (rooms 51/84) that placement table structurally cannot
        ;    recover -- see derive_room_cmask's own comment and NOTES.md
        ;    "Rooms 51/84 need their 6 bytes back".
        jsr derive_room_cmask
        ; 2. rd_sortplaces: build the y-sorted RAM copy + 16px band index
        ;    (T0064) the draw path still needs, from that same
        ;    SOURCE-order table.
        jsr rd_sortplaces

        ; NOW repoint room_placements_ptr/end/room_place_bands_ptr at the
        ; RAM buffers rd_sortplaces just built -- everything from here on
        ; (redraw_placements_dmg and friends) reads THESE, never the ROM
        ; source table again until the next load_room.
        if FLOPPY
        lda sp_count              ; T0261: + the run-time clipped placements (clip_room_add)
        else
        lda room_place_count      ; sp_addr (rd_sortplaces's own helper):
        endif
        jsr sp_addr                 ; X = ROOM_PLACE_SORTED + count*4
        stx room_placements_end
        ldd #ROOM_PLACE_SORTED
        std room_placements_ptr
        ldd #ROOM_PLACE_BANDS
        std room_place_bands_ptr
        rts
lr_unknown
        ; No data for that room in this build. Leave the previous room's
        ; pointers alone rather than drawing through a null one -- the
        ; transitions gate on this same table, so this is unreachable,
        ; and it fails harmlessly if that ever stops being true.
        rts

; ======================================================================
; T0163 (Change 1, runtime half): derive_room_cmask + rd_sortplaces.
;
; SPEC is tools/roompack/src/main.rs's own cmask loop (~line 1441+),
; proved offline against every built room by tools/derive_cmask.py --
; see NOTES.md "Change 1 PROVED OFFLINE". Two passes over the SAME
; SOURCE-order placement list (room_placements_ptr/end, still pointing
; at ROM at the point load_room calls this):
;
;   pass 1 (dc_pass1_place): paints ATTR_CELLS, one bit per 8x8-pixel
;   cell over the 32x24 grid -- 1 = "the last placement to cover this
;   cell was decorative (its own DECORATIVE bit set)". LAST WRITER WINS,
;   which is why this has to walk placements in SOURCE order (roompack's
;   own comment, and NOTES.md's "the catch": y-sorted breaks 6 of 27
;   rooms). Unconditional overwrite per placement, never OR/AND.
;
;   pass 2 (dc_pass2_place): for every placement whose OWN DECORATIVE
;   bit is clear, rasterise its real ink (mirrored about its own width
;   if the placement is mirrored) into CUR_ROOM_CMASK, skipping any
;   pixel whose 8x8 cell was painted decorative in pass 1. Ink drawing
;   is order-independent (OR-composited), so pass 2's own order doesn't
;   matter -- only pass 1's does.
;
; Every width/x addition here that can exceed 255 (screen width) is done
; in 16-bit (D), never truncated to a byte: rooms 22/50/51/54/57/67/68
; all have real placements whose x+width runs past 255, and a byte-only
; add would wrap those into a SMALL, in-range-looking value instead of
; correctly recognising "off the right edge, stop" -- silently painting
; the wrong cells. (The mirror image of the "negative pixel_x" landmine
; NOTES.md already flags on the offline/roompack side.)
; ======================================================================

; --------------------------------------------------------------------
; dc_load_placement: read one 3-byte placement record (T0167 -- frame
; INDEX, not a 2-byte sprite pointer) from ,x (advancing X past it),
; decode its flag bits, resolve the index through frame_table, and fill
; dc_* fields. Does NOT touch dc_saved_x's caller-visible X -- callers
; save/restore their own iteration pointer around the jsr. Room-load
; time only (derive_room_cmask), so the extra MUL/table-load here is
; not a per-frame cost -- see rd_placelp/rd_sortplaces for the path that
; actually runs every frame.
; --------------------------------------------------------------------
dc_load_placement
        lda ,x+                  ; A = frame_table index (kept for the
                                   ; MUL below -- nothing between here and
                                   ; there touches A)
        ldb ,x+                  ; B = pixel_x, with T0142/T0163's flag bits
        stb dc_xraw                ; kept RAW; callers test bit 0 (mirror) /
        andb #$fc                  ; bit 1 (dull) directly rather than this
        stb dc_xm                   ; routine isolating each into its own byte
        ldb ,x+                  ; B = y
        stx dc_saved_x            ; done reading this 3-byte record
        stb dc_y

        ldb #2
        mul                       ; D = index*2 (frame_table is fdb-per-entry)
        addd #frame_table
        tfr d,x                    ; X is free -- caller reloads it from
                                    ; dc_saved_x, never from us
        ldu ,x                    ; U = sprite header ptr (w,h,bpr,bitmap)
        lda ,u
        sta dc_w
        lda 1,u
        sta dc_h
        lda 2,u
        sta dc_bpr
        leau 3,u                 ; U -> bitmap data (past the header)
        stu dc_sprite
        rts

; dc_cellend: in A = a cell index (dc_cy or dc_cx), X = ptr to a 16-bit
; end limit (dc_yend or dc_xend). Sets flags as if `cmpd #(A*8)` against
; ,x -- caller does BHS/BLO right after the jsr (RTS doesn't touch CC).
; MUL gives the true 16-bit product directly, so this needs no 16-bit-
; safety comment of its own the way the ADDs building dc_yend/dc_xend do.
dc_cellend
        ldb #8
        mul
        cmpd ,x
        rts

; dc_bitofs (T0163) was removed by T0164: it was hardwired to X (its own
; ABX), and once dc_pass2_place's byte loop started relying on X to walk
; the sprite bitmap ACROSS calls (T0164, "eliminate the row multiply"),
; that became a real bug -- dc_p2_cell's own address math clobbered the
; caller's X. The fix was to move that address math to Y/U instead of
; sharing this X-based routine (see dc_p2_cell's own comment); with that
; done, dc_bitofs had no callers left.

; --------------------------------------------------------------------
; dc_pass1_place: paint ATTR_CELLS over dc_xm/dc_y's 8x8-cell bounding
; box (dc_w x dc_h pixels) with dc_dull (SET if dull, CLEAR if not).
; --------------------------------------------------------------------
dc_pass1_place
        clra                      ; dc_yend = dc_y + dc_h -- always <256
        ldb dc_h                   ; (checked offline against every built
        addb dc_y                   ; room: y+h never crosses it), so no
        std dc_yend                  ; adca #0 needed the way dc_xend's does.
        clra                      ; dc_xend = dc_xm + dc_w, 16-bit-safe
        ldb dc_w
        addb dc_xm
        adca #0
        std dc_xend

        lda dc_y
        lsra
        lsra
        lsra
        sta dc_cy
dc1_rowlp
        lda dc_cy
        cmpa #ATTR_CELLS_H
        bhs dc1_rowdone
        ldx #dc_yend
        jsr dc_cellend             ; carry-equivalent BHS if dc_cy*8 >= dc_yend
        bhs dc1_rowdone

        lda dc_xm
        lsra
        lsra
        lsra
        sta dc_cx
dc1_collp
        lda dc_cx
        cmpa #ATTR_CELLS_W
        bhs dc1_coldone
        ldx #dc_xend
        jsr dc_cellend
        bhs dc1_coldone

        jsr dc_attr_write

        inc dc_cx
        bra dc1_collp
dc1_coldone
        inc dc_cy
        bra dc1_rowlp
dc1_rowdone
        rts

; dc_attr_write: set ATTR_CELLS[dc_cy][dc_cy] to dc_dull -- ONE BYTE per
; cell (see ATTR_CELLS's own comment above), so this is a plain
; row-major store, no bit machinery: LAST WRITER WINS is just an
; unconditional `sta`, never OR.
dc_attr_write
        lda dc_cy
        ldb #ATTR_CELLS_W
        mul
        addd #ATTR_CELLS
        tfr d,x
        ldb dc_cx
        abx
        lda dc_xraw
        anda #2                  ; dull flag (bit 1) -- see dc_load_placement
        sta ,x
        rts

; --------------------------------------------------------------------
; dc_pass2_place (T0164, byte-wise -- see NOTES.md "Change 1 runtime --
; CORRECT but 40x TOO SLOW"): for a non-dull placement, rasterise its
; real ink into CUR_ROOM_CMASK, skipping any pixel whose ATTR_CELLS
; cell is set. Was per-pixel (8 bit-tests per source byte); now
; per-BYTE: every placement x (dc_xm) is a multiple of 4 and every
; sprite width (dc_w) is a multiple of 4 ("4 pixels=1 unit", NOTES.md),
; so one source byte (8 pixels, MSB first) covers EXACTLY TWO 4px mask
; cells and never a partial one mid-byte -- the high nibble is the
; lower-x cell, the low nibble the higher-x cell. Test each nibble
; ONCE (~2 ops) instead of its 8 bits one at a time.
;
; The only nibble that can be invalid is the LOW nibble of the LAST
; byte in a row, and only when dc_w&7 == 4 (a multiple of 4 but not
; 8) -- padding bits are real memory past the real ink, not guaranteed
; zero, so this can't be assumed harmless. Rather than special-case
; "is this the last byte", dc_p2_cell bounds-checks the relcell it's
; given against dc_ncm1 (relcell > ncm1 means "past the real width",
; which can ONLY happen for that one padding nibble -- the high nibble
; of every byte up to dc_bpr-1 is always a real column by construction,
; dc_bpr = ceil(dc_w/8), and every other low nibble is too).
;
; Mirror (T0142 bit 0): the old per-pixel code mapped output column c
; to source column w-1-c (dc2_haved's own math). One level up, at cell
; granularity, a NON-mirrored byte i contributes cells (2i, 2i+1) in
; left-to-right order; reflecting the whole row about its own width
; turns that into cells ((ncells-1)-2i, (ncells-1)-2i-1) -- i.e. every
; non-mirrored cell index k becomes (ncells-1)-k, independent of which
; nibble or byte it came from. That is "reverse byte order and reverse
; nibble order within each byte", just computed as one reflection
; instead of two: verified column-by-column against dc2_haved's
; per-pixel definition for both dc_w&7==0 and dc_w&7==4 before this
; replaced it, then confirmed empirically by harness/cmaskverify.lua
; (same 23-identical/2-landmine result as the per-pixel version).
;
; dc_ncm1/dc_bytei below are EQU aliases onto dc_cy/dc_dcol -- pass 1
; (dc_pass1_place, ATTR painting) has fully finished
; for EVERY placement before derive_room_cmask's pass-2 loop calls this
; at all, so nothing of pass 1's is live across that boundary and no
; new scratch bytes are needed (the code+data region has 3 bytes spare).
; --------------------------------------------------------------------
dc_ncm1      equ dc_cy
dc_bytei     equ dc_dcol
dc_cmaskrow  equ dc_xend             ; row-address scratch (dc_xend is
                                     ; pass-1-only, free during pass 2)

dc_pass2_place
        lda dc_w
        lsra
        lsra                      ; A = ncells = w>>2 (w is a multiple of 4)
        deca
        sta dc_ncm1                ; ncells-1 -- bounds limit for relcell,
                                     ; and the mirror reflection point

        ; T0166: dc_mirrored/dc_basecc, PLACEMENT-constant (dc_xraw/dc_xm
        ; don't change within one dc_pass2_place call), computed ONCE
        ; here rather than once per ink-bearing nibble inside dc_p2_cell
        ; -- see dc_p2_cell's own comment for what this replaces (the old
        ; relcell*4 + dc_xm 8-bit-safe add/shift chain).
        lda dc_xraw
        anda #1
        sta dc_mirrored
        lda dc_xm
        lsra
        lsra
        sta dc_basecc              ; xm>>2 -- xm is a multiple of 4, exact

        ldx dc_sprite             ; X = row 0's bitmap start. NOT
                                     ; recomputed per row below by design:
                                     ; the byte loop's own ",x+" already
                                     ; advances X by dc_bpr bytes over a
                                     ; full row (one auto-increment per
                                     ; byte, unconditional, whether or not
                                     ; that byte's nibbles are ink), which
                                     ; is exactly the next row's start --
                                     ; a row*bpr multiply every row would
                                     ; just recompute what X already is.
        clr dc_row
dc2_rowlp
        lda dc_row
        cmpa dc_h
        lbhs dc2_rowdone            ; LONG branch: the inlined byte loop
                                     ; (T0166) pushed dc2_rowdone out of
                                     ; short-branch range
        lda dc_y
        adda dc_row               ; T0187: py = y+row IS the mask row
        sta dc_cr

        ; CUR_ROOM_CMASK's row address is the same for every nibble in
        ; this row (it depends only on dc_cr, not on which cell), so
        ; compute it here -- ONCE per row -- rather than inside
        ; dc_p2_cell (cmasktime.lua showed that MUL running for every
        ; ink-bearing nibble in the room: ~38 of ~49 frames for room 36's
        ; initial load, before this hoist -- T0163).
        lda dc_cr
        ldb #CM_STRIDE
        mul
        addd #CUR_ROOM_CMASK
        std dc_cmaskrow

        ; T0166: ATTR_CELLS' row address is ALSO row-constant and gets
        ; the same treatment now that the stored-mask removal freed the
        ; code space this used to lack (T0163's comment: "hoisting BOTH
        ; overflowed the 8-byte title-hole spare by 5 bytes"). This was
        ; the OTHER per-nibble MUL cmasktime.lua's profile pointed at.
        lda dc_cr
        lsra                        ; T0187: attr-cell row = py >> 3
        lsra
        lsra
        ldb #ATTR_CELLS_W
        mul
        addd #ATTR_CELLS
        std dc_attrrow

        clr dc_bytei
dc2_bytelp
        lda dc_bytei
        cmpa dc_bpr
        lbhs dc2_bytedone           ; LONG branch, same reason as above

        lda ,x+                  ; the one source byte for this cell pair --
                                     ; X is left pointing PAST it, so the low
                                     ; nibble test below re-reads it via -1,x
                                     ; (a 2-byte indexed load) instead of a
                                     ; round trip through a scratch byte.
        anda #$f0                  ; high nibble -> relcell = 2*bytei
        beq dc2_hiskip
        lda dc_bytei
        lsla
        ; T0166: dc_p2_cell INLINED here (and again below for the low
        ; nibble) -- removes the JSR/RTS this used to cost per
        ; ink-bearing nibble. See dc_p2_cell's own (now-removed) comment
        ; for what this sequence means; nothing here changed except
        ; where it lives.
        cmpa dc_ncm1
        bhi dc2_hiskip              ; relcell >= ncells -> padding nibble
        tst dc_mirrored
        beq dc2_hioff
        nega
        adda dc_ncm1
dc2_hioff
        adda dc_basecc
        cmpa #64
        bhs dc2_hiskip              ; off the right edge (>63 -> >255px)
        sta dc_cc
        ldy dc_attrrow
        ldb dc_cc
        lsrb
        lda b,y
        bne dc2_hiskip             ; decorative cell -> not collidable
        ldy dc_cmaskrow
        lda dc_cc
        tfr a,b
        andb #7                    ; B = cc&7 -- bit within the byte
        lsra
        lsra
        lsra                        ; A = cc>>3 -- byte within the row
        leay a,y
        ldu #cm_bittab
        lda b,u
        ora ,y
        sta ,y
dc2_hiskip
        lda -1,x                  ; low nibble -> relcell = 2*bytei+1;
        anda #$0f                  ; the bounds check below catches the
        beq dc2_bytenext            ; one case (last byte, w&7==4) where
        lda dc_bytei                ; that isn't a real column
        lsla
        inca
        cmpa dc_ncm1
        bhi dc2_bytenext
        tst dc_mirrored
        beq dc2_looff
        nega
        adda dc_ncm1
dc2_looff
        adda dc_basecc
        cmpa #64
        bhs dc2_bytenext
        sta dc_cc
        ldy dc_attrrow
        ldb dc_cc
        lsrb
        lda b,y
        bne dc2_bytenext
        ldy dc_cmaskrow
        lda dc_cc
        tfr a,b
        andb #7
        lsra
        lsra
        lsra
        leay a,y
        ldu #cm_bittab
        lda b,u
        ora ,y
        sta ,y
dc2_bytenext
        inc dc_bytei
        lbra dc2_bytelp             ; LONG branch, same reason as above
dc2_bytedone
        inc dc_row
        lbra dc2_rowlp              ; LONG branch, same reason as above
dc2_rowdone
        rts

; T0166: dc_p2_cell (the per-cell reflect+ATTR-skip+CUR_ROOM_CMASK-set
; routine) is gone -- INLINED directly into dc_pass2_place's byte loop,
; once for the high nibble and once for the low (see that routine's own
; comment). Removing the JSR/RTS this cost per ink-bearing nibble (2571
; of them for room 36 alone) was worth doing once the stored-mask
; removal freed the code space; measured with harness/cmasktime.lua.

; --------------------------------------------------------------------
; derive_room_cmask: walk room_placements_ptr..room_placements_end
; (SOURCE order) twice into CUR_ROOM_CMASK, then applies dc_patch (the
; handful of cells rooms 51/84 need back -- see its own comment). Called
; by load_room BEFORE room_placements_ptr/end are repointed at the
; sorted RAM copy.
; --------------------------------------------------------------------


derive_room_cmask
        ldx #CUR_ROOM_CMASK   ; clear both scratch buffers -- they're
        ldd #0                     ; adjacent by construction (see the
        ldy #(CMASK_BYTES+ATTR_CELLS_LEN)/2   ; equ block above)
dc_clrlp
        std ,x++
        leay -1,y
        bne dc_clrlp

        ldx room_placements_ptr
dc_p1lp
        cmpx room_placements_end
        bhs dc_p1done
        jsr dc_load_placement
        jsr dc_pass1_place
        ldx dc_saved_x
        bra dc_p1lp
dc_p1done

        ldx room_placements_ptr
dc_p2lp
        cmpx room_placements_end
        bhs dc_p2done
        jsr dc_load_placement
        lda dc_xraw
        anda #2                   ; dull flag (bit 1)
        bne dc_p2skip             ; dull placements never contribute ink
        jsr dc_pass2_place
dc_p2skip
        ldx dc_saved_x
        bra dc_p2lp
dc_p2done
        jsr dc_patch
        rts

; --------------------------------------------------------------------
; dc_patch (T0166, "Rooms 51/84 need their 6 bytes back", NOTES.md):
; ORs a handful of hardcoded cells back into CUR_ROOM_CMASK for the two
; rooms whose negative-pixel_x placements roompack drops from the
; SHIPPED room_placements table entirely (its own `(0..256).contains`
; filter) -- nothing derived from that table can recover them, because
; they are not IN it, not because the derivation is wrong. The original
; clips and draws the visible sliver of each (this port's blit cannot
; clip), so the ORIGINAL still collides there; skipping the patch would
; make those cells walkable when they should not be.
;
; Each entry is (room:1, offset:2, orbyte:1), table terminated by a
; room byte of 0 (no built room is 0). Derived from tools/derive_cmask.py
; ("full" -- every placement, including negative pixel_x, exactly as
; roompack's own algorithm computes it when nothing is filtered --
; against a second derivation that drops the same placements the SHIPPED
; table drops): every offset here is where those two derivations differ,
; and the OR is (full & ~restricted) at that offset -- purely additive in
; both rooms, never a bit that needs clearing. See NOTES.md's own
; comment for the exact numbers this table encodes.
; --------------------------------------------------------------------
dc_patch
        ldx #dc_patch_tab
dc_patch_lp
        lda ,x+
        beq dc_patch_done          ; room 0 = terminator
        cmpa cur_room
        beq dc_patch_apply
        leax 3,x                    ; not this room -- skip offset+orbyte
        bra dc_patch_lp
dc_patch_apply
        ; T0187: the table stays CELL-granular, so each entry paints FOUR
        ; consecutive 1px rows (regenerated at true 1px it would be 223
        ; entries / 892 bytes -- see NOTES.md).
        ldd ,x++                   ; D = offset of the FIRST of 4 rows
        addd #CUR_ROOM_CMASK
        tfr d,y
        lda ,x+                    ; orbyte, leaves X at the next entry
        ldb #4
dc_patch_row
        ora ,y
        sta ,y
        leay CM_STRIDE,y
        decb
        bne dc_patch_row
        bra dc_patch_lp
dc_patch_done
        rts

dc_patch_tab
        fcb 51
        fdb 1088
        fcb $f0
        fcb 51
        fdb 1120
        fcb $10
        fcb 84
        fdb 1024
        fcb $f0
        fcb 84
        fdb 1056
        fcb $f0
        fcb 84
        fdb 1088
        fcb $f0
        fcb 84
        fdb 1120
        fcb $f0
        ; T0??? -- room 60 BASE OF THE VOLCANO has the same landmine: one
        ; off-screen-at-spawn placement (frame 211, pixel_x -8) dropped from
        ; the SHIPPED room_placements table, whose on-screen sliver the
        ; original still collides with. Computed the same way as 51/84
        ; (tools/derive_cmask.py's "full" derivation vs a second derivation
        ; that drops the same placement roompack's shipped table drops,
        ; effective_attrs taken from the untouched full list): 2 bytes,
        ; offsets 320/328, OR $fc.
        fcb 60
        fdb 1280
        fcb $fc
        fcb 60
        fdb 1312
        fcb $fc
        if TAPE_ROOMS
        ; T0232 -- room 47 FOURWAY WAREHOUSE (tape-only room), the way up to
        ; coin 63.  Placement 49 is frame 58, an 8x8 BLANK at (152,72) whose
        ; solid attribute (14) overwrites the thatch roof's (frame 201,
        ; attribute 70 = dull) in that one 8x8 cell.  The original's
        ; checkline finds the ROOF'S INK on screen and checkattri calls it
        ; solid, so Dizzy can stand on feet y=71 at x 136..152 and jump from
        ; there into room 63; pass 2 skips the dull roof placement and the
        ; port had nothing there.  Measured on the ORIGINAL (exits_zx drop
        ; scan from y=70: x 136..152 land at feet 71, every other column
        ; lands lower).  The cells are tools/derive_cmask.py all_ink minus
        ; 'full' for room 47 at rows 72..79, cols x=152,156 (two 4-row
        ; entries; (79,156) is the only extra cell -- interior, no surface).
        ; Gated: the -run build (room36.bin) has no room 47 and stays
        ; byte-identical.
        fcb 47
        fdb 580
        fcb $03
        fcb 47
        fdb 612
        fcb $03
        endif
        fcb 0                       ; terminator

; ======================================================================
; rd_sortplaces: build the y-sorted RAM copy of this room's placements
; (ROOM_PLACE_SORTED) plus its 16px-band start index (ROOM_PLACE_BANDS,
; T0064) from the SOURCE-order table at room_placements_ptr/end -- see
; the big comment above. A stable insertion sort: at most ROOM_PLACE_MAX
; (128) records, each up to ROOM_PLACE_MAX-1 shifts of 4 bytes -- a
; once-per-room-change cost, not a per-frame one (harness/rate.lua
; measures it directly).
; ======================================================================
; sp_addr: in A = index into ROOM_PLACE_SORTED, out X = its address.
; MUL, not lslb/abx: rooms with >63 placements (room 72 has 95) push
; index*4 past 255, which an 8-bit shift-and-add would silently wrap.
sp_addr
        ldb #4
        mul
        addd #ROOM_PLACE_SORTED
        tfr d,x
        rts

rd_sortplaces
        clr sp_count
        ldx room_placements_ptr
sp_lp
        cmpx room_placements_end
        bhs sp_sorted
        ; T0167: source record is now 3 bytes (frame_table index, x, y),
        ; not 4 (a 2-byte sprite pointer). Resolve the index through
        ; frame_table HERE, once per room load, and build sp_new as the
        ; SAME 4-byte (ptr,x,y) record rd_placelp always read -- the
        ; per-frame draw path stays exactly as cheap as before; only
        ; this once-per-room-change sort pays the extra lookup.
        lda ,x+                  ; A = frame_table index
        ldb #2
        mul                       ; D = index*2
        addd #frame_table
        tfr d,y
        ldd ,y                    ; D = resolved sprite header ptr
        std sp_new                 ; sp_new[0,1] = ptr
        ldd ,x++                   ; D = x,y (2 raw bytes) -- not
        std sp_new+2                ; interpreted here, same as before.
        stx sp_srcx

        lda sp_count
        deca
        sta sp_j
sp_findlp
        lda sp_j
        bmi sp_found
        jsr sp_addr
        lda 3,x                  ; sorted[j].y
        cmpa sp_new+3
        bls sp_found              ; sorted[j].y <= new.y -> insert after j (stable)
        ldd ,x                     ; shift sorted[j] -> sorted[j+1] (4 bytes)
        std 4,x
        ldd 2,x
        std 6,x
        dec sp_j
        bra sp_findlp
sp_found
        lda sp_j
        inca
        jsr sp_addr
        ldd sp_new
        std ,x
        ldd sp_new+2
        std 2,x
        inc sp_count
        ldx sp_srcx
        bra sp_lp
sp_sorted
        if FLOPPY
        jsr clip_room_add         ; T0261
        endif
        jsr sp_build_bands
        rts

; sp_build_bands: single forward pass (both sp_idx and the band's own
; top are non-decreasing, so this never has to re-scan from the start).
sp_build_bands
        clr sp_idx
        clr sp_band
sp_band_lp
        lda sp_band
        cmpa #12
        bhs sp_bands_done
        ldb #16
        mul                       ; top = band*16 (A already = sp_band)
        stb sp_top
sp_advance
        lda sp_idx
        cmpa sp_count
        bhs sp_have_start          ; ran out of placements -> point at the end
        jsr sp_addr
        ldu ,x                    ; U = this placement's sprite header
        lda 3,x                   ; A = y
        adda 1,u                   ; A = y+height (<256, checked offline)
        cmpa sp_top
        bhi sp_have_start          ; y+height > top -> first band-reaching one
        inc sp_idx
        bra sp_advance
sp_have_start
        lda sp_idx
        jsr sp_addr
        ldb sp_band
        lslb
        ldy #ROOM_PLACE_BANDS
        stx b,y
        inc sp_band
        bra sp_band_lp
sp_bands_done
        rts

; --- T0163 scratch variables --------------------------------------
dc_sprite     fdb 0
dc_saved_x    fdb 0
dc_yend       fdb 0
dc_xend       fdb 0
dc_xm         fcb 0
dc_y          fcb 0
dc_xraw       fcb 0
dc_w          fcb 0
dc_h          fcb 0
dc_bpr        fcb 0
dc_cy         fcb 0
dc_cx         fcb 0
dc_row        fcb 0
dc_dcol       fcb 0
dc_cr         fcb 0
dc_cc         fcb 0
dc_attrrow    fdb 0     ; T0166: ATTR_CELLS row address, hoisted once per
                          ; outer row by dc_pass2_place (see its comment)
dc_mirrored   fcb 0     ; T0166: placement-constant, hoisted once per
                          ; placement (was tested per ink-bearing nibble)
dc_basecc     fcb 0     ; T0166: dc_xm>>2, same hoist
sp_new        fdb 0
              fcb 0,0
sp_srcx       fdb 0
sp_count      fcb 0
sp_j          fcb 0
sp_idx        fcb 0
sp_band       fcb 0
sp_top        fcb 0

; Every room this build contains. Adding one is: generate its data,
; include it in a staging block, and add a line here.
room_desc_table
        fdb r36_room_desc
        fdb r35_room_desc
        fdb r51_room_desc
        fdb r52_room_desc
        fdb r53_room_desc
        fdb r54_room_desc
        fdb r68_room_desc
        fdb r69_room_desc
        fdb r55_room_desc
        fdb r67_room_desc
        fdb r84_room_desc
        fdb r85_room_desc
        fdb r83_room_desc        ; T0120
        fdb r86_room_desc
        fdb r100_room_desc
        fdb r70_room_desc        ; empty sky between 86 and 54
        fdb r87_room_desc        ; T0122
        fdb r50_room_desc        ; T0123
        fdb r56_room_desc        ; T0124
        fdb r71_room_desc        ; T0124
        fdb r39_room_desc        ; T0125
        fdb r23_room_desc        ; T0125
        fdb r57_room_desc        ; T0159
        fdb r24_room_desc        ; T0159
        fdb r72_room_desc        ; T0161
        fdb r22_room_desc        ; T0162
        fdb r58_room_desc        ; T0??? -- 58 THE SMELLY ALLOTMENT, chains off 57 (57+1)
        fdb r59_room_desc        ; T0??? -- 59 THE LARGE OAK TREE, chains off 58 (58+1)
        fdb r60_room_desc        ; T0??? -- 60 BASE OF THE VOLCANO, chains off 59 (59+1)
        fdb r76_room_desc       ; T0222
        if TAPE_ROOMS
        fdb r74_room_desc      ; T0230 -- 58+16, tape-only region
        fdb r75_room_desc      ; T0230 -- 59+16, tape-only region
        ; T0233-fix: touch point 3 of T0222's six -- MISSED for all 16 of
        ; these when they were first added (NOTES.md T0233's own
        ; cmaskverify triage found it: load_room's lr_scan never matched
        ; these room numbers, so it hit lr_unknown and silently left the
        ; PREVIOUS room's mask/placements in place -- jumptrace's own
        ; "floor=1" reports for these rooms were bogus, reading room 36's
        ; stale geometry at each room's own spawn x, not the new room's).
        fdb r63_room_desc
        fdb r91_room_desc
        fdb r92_room_desc
        fdb r45_room_desc
        fdb r48_room_desc
        fdb r49_room_desc
        fdb r94_room_desc
        fdb r89_room_desc
        fdb r41_room_desc
        fdb r73_room_desc
        fdb r88_room_desc
        fdb r93_room_desc
        fdb r40_room_desc
        fdb r46_room_desc
        fdb r31_room_desc
        fdb r47_room_desc
        fdb r77_room_desc      ; T0233-fix -- THE ACTIVE VOLCANO, water-phase fix
        endif
        fdb 0


; test_spin: inert landing pad for headless test harnesses that
; synthesize a JSR into some routine (e.g. blitdizzy) via a fake return
; address -- returning into `mainloop` instead runs real game logic
; (redraw etc.) that can overwrite whatever the test just set up before
; it gets dumped. Never reached during normal play.
test_spin
        bra test_spin

; --------------------------------------------------------------------
; scankeys: reads the keyboard matrix directly via PIA0 ($FF00/$FF02),
; NOT the ROM's POLCAT vector -- see NOTES.md "Keyboard input research"
; (T0017) for the confirmed matrix layout and why raw scanning was
; chosen. Deliberately skips PIA0 data-direction-register setup, relying
; on BASIC having already configured it correctly for its own keyboard
; polling (also documented there, along with the fallback plan if this
; assumption turns out wrong).
; Up/down/left/right all live in matrix row 3, at columns 3/4/5/6
; respectively; row bit 3 of $FF00, 0=pressed (inverted from what you'd
; expect -- the source doc flags this explicitly).
; Sets keyflags: bit0=up, bit1=down, bit2=left, bit3=right, 1=pressed.
; --------------------------------------------------------------------
        if TAPE_ROOMS
; T0240: the tape build's scankeys is a 5-column loop (the -run build keeps the
; unrolled original below, byte for byte).  The row-3 bit of each column is
; rotated into keyflags, columns 3..7 = UP, DOWN, LEFT, RIGHT, SPACE, then
; flipped and aligned to bit0=up .. bit4=space.  Ends in joy_fire (the
; joystick buttons = SPACE; tape_joy_code.asm).
scankeys
        ldb #%11110111         ; column 3 select; the mask walks left to column 7
sk_lp   stb $ff02
        lda $ff00
        lsra
        lsra
        lsra
        lsra                   ; row bit 3 -> carry (1 = released)
        ror keyflags
        orcc #1
        rolb                   ; next column; carry out is 0 after column 7
        bcs sk_lp
        lda keyflags           ; results sit in bits 7..3
        lsra
        lsra
        lsra
        eora #$1f              ; 1 = pressed
        sta keyflags
        jmp joy_fire
        else
scankeys
        clr keyflags

        lda #%11110111  ; column 3 = up
        sta $ff02
        lda $ff00
        anda #%00001000
        bne sk_noup
        lda keyflags
        ora #1
        sta keyflags
sk_noup
        lda #%11101111  ; column 4 = down
        sta $ff02
        lda $ff00
        anda #%00001000
        bne sk_nodown
        lda keyflags
        ora #2
        sta keyflags
sk_nodown
        lda #%11011111  ; column 5 = left
        sta $ff02
        lda $ff00
        anda #%00001000
        bne sk_noleft
        lda keyflags
        ora #4
        sta keyflags
sk_noleft
        lda #%10111111  ; column 6 = right
        sta $ff02
        lda $ff00
        anda #%00001000
        bne sk_noright
        lda keyflags
        ora #8
        sta keyflags
sk_noright
        lda #%01111111  ; column 7 = space (message dismiss -- see flip_buffer)
        sta $ff02
        lda $ff00
        anda #%00001000
        bne sk_nospace
        lda keyflags
        ora #16
        sta keyflags
sk_nospace
        rts
        endif

; --------------------------------------------------------------------
; delay: crude fixed busy-wait so movement is human-controllable instead
; of instant. Not frame/vsync-synced -- a real game loop would tie this
; to the video timer, not a cycle-counted spin; fine for this slice.
; --------------------------------------------------------------------
; --------------------------------------------------------------------
; pace_frame: hold each mainloop pass to a whole number of 60Hz vsync
; pulses, so extra CPU headroom (see OVERCLOCK) becomes CONSISTENT speed
; rather than a game that plays faster than the original.
;
; The 60Hz field rate is generated by the VDG and is NOT affected by the
; SAM rate bits, so it stays a valid wall-clock reference even at 2x --
; which is exactly why pacing on it is right and a fixed cycle-count
; spin (the old `delay`) is wrong: the spin would halve in duration the
; moment the clock doubled.
;
; NOT a deadline check -- these waits always cost their full time, even
; on a pass that ran short. That is why FRAME_PULSES is conditional on
; OVERCLOCK (see above) instead of being safe to leave on unconditionally.
; --------------------------------------------------------------------
pace_frame
        if FRAME_PULSES > 0
        lda #FRAME_PULSES
pf_lp
        pshs a
        jsr wait_vsync
        puls a
        deca
        bne pf_lp
        endif
        rts

delay
        ldd #DELAY_COUNT
delaylp
        subd #1
        bne delaylp
        rts


; --------------------------------------------------------------------
; T0067: room transitions, by the ORIGINAL'S OWN ARITHMETIC rather than
; a hand-written routine per direction per room.
;
; The map is a grid and there is no exit table anywhere in the game --
; `goneleft`/`goneright`/`goneup`/`gonedown` (X-ALL.TXT ~6298) are the
; whole of it:
;
;     left   roomno - 1    x := 56 units = 224px
;     right  roomno + 1    x := 2 units  = 8px
;     up     roomno + 16
;     down   roomno - 16
;     then `and 127`
;
; (games/dizzy/recipe/MAP.md). Four rooms meant four copy-pasted
; routines plus a cur_room compare chain at every screen edge; eight
; would have meant eight. Now the arithmetic runs once, and the only
; per-build question left is "does this build HAVE that room", answered
; from the same room_desc_table load_room reads -- so the two can never
; disagree. An unbuilt neighbour is simply an edge you can't walk
; through, which is also exactly what it looks like in play.
;
; Arrival y for the vertical moves stays this port's own pair (160 up,
; 74 down) rather than the source's `y +/- 118/114`: the source keeps
; Dizzy's vertical velocity across the transition and lets him carry on
; rising through the hole, while this port re-settles him from scratch.
; 74 is load-bearing -- see T0056, the "stuck on top of the wall" trap.
; --------------------------------------------------------------------
room_transition_up
        lda cur_room
        adda #16
        anda #127                ; the source's own `and 127`
        sta rt_newroom
        lda dizzy_y              ; T0117: goneup `ld a,(y) / add a,118`
        adda #118
        sta rt_arrive
        bra rt_vertical

room_transition_down
        lda cur_room
        suba #16
        anda #127
        sta rt_newroom
        ; T0056: 74, not 56. Arriving at 56 puts Dizzy's feet 1px below
        ; room 36's y=48-55 wall row, and the next vertical pass lifts
        ; him STEP_UP (4px) before scanning for floor -- the step-climb
        ; doing its job (T0031) -- landing him INSIDE the wall, where
        ; check_ground reports solid and he can walk its whole span.
        ; `gonedown` avoids it by construction: y-114 from a threshold
        ; of 182 arrives at 68; this port's threshold is 188, so 74.
        ; T0117: computed as gonedown's own `sub 114` -- the 1px scan
        ; always reaches exactly 188 here, so it is still 74.
        lda dizzy_y
        suba #114
        sta rt_arrive
rt_vertical
        jsr well_route           ; T0125: X-ALL.TXT newroom's well special cases
        lda rt_newroom
        jsr room_exists
        tsta
        bne rt_exists
        ; T0076: an unbuilt vertical neighbour is only a wall if something
        ; here acts like one. Horizontally, check_wall stops dizzy_x from
        ; ever changing before room_transition_left/right is even called --
        ; the "edge you can't walk through" comment above is really
        ; describing check_wall, not this routine. Vertically there is no
        ; equivalent: check_ceiling/check_ground pass Dizzy through a real
        ; GAP in the room's own wall art (that gap is what makes the
        ; transition reachable at all in a built room), so by the time we
        ; get here his dy is still whatever the jump/fall left it as. Doing
        ; nothing here left him rising or falling forever through an
        ; opening that looks solid from outside but has nothing behind it
        ; once the neighbour doesn't exist -- exactly room 51's "jump out
        ; the top and never come down" (dead end above `check_ceiling` -->
        ; NOTES.md T0076) and the equivalent for a bottom gap. `clr
        ; dizzy_dy` is ml_bonk's own fix for hitting a real ceiling ("stop
        ; rising, fall back") -- applying it here makes a missing neighbour
        ; behave the same as a real one, both directions, for free.
        clr dizzy_dy
        lbra ml_vertdone
rt_exists
        lda rt_newroom
        sta cur_room
        jsr load_room
        lda rt_arrive
        sta dizzy_y              ; x unchanged, matching goneup/gonedown
        jsr rt_settle
        lbra ml_vertdone

room_transition_left
        lda cur_room
        deca
        sta rt_newroom
        lda #224                 ; goneleft: `ld a,56`, x4 for the unit
        sta rt_arrive
        bra rt_horizontal

room_transition_right
        lda cur_room
        inca
        sta rt_newroom
        lda #8                   ; goneright: `ld a,2`, x4 for the unit
        sta rt_arrive
rt_horizontal
        lda rt_newroom
        jsr room_exists
        tsta
        lbeq ml_dirdone          ; nothing built that way: stay put
        lda rt_newroom
        sta cur_room
        jsr load_room
        lda rt_arrive
        sta dizzy_x              ; y unchanged, matching goneleft/right
        jsr rt_settle
        ; T0192: skip the REST of this pass's Dizzy update, exactly as
        ; room_transition_up/down already do. X-ALL.TXT's `newroom` sets
        ; `dontupdatedizzy=1` and the main loop then does
        ;   ld a,(dontupdatedizzy) / and a / call z,updatedizzy
        ; so the original runs NO movement, gravity or animation on the
        ; tick it changes room. This fell through to ml_dirdone instead,
        ; which runs the jump test AND the whole vertical section, so the
        ; port came out of every horizontal crossing ONE vertical step
        ; ahead of the original. Traced on 68@32,148 JUMPLEFT: identical
        ; to the pixel until the crossing, then port x=224 y=120 dy=-1
        ; against the original's y=121 dy=-2 -- and 2px is the whole
        ; margin on room 67's dithered rock face, where check_wall's
        ; y-10/y-14/y-18 probes (the source's own rows) hit ink at y=123
        ; and miss it at y=121. The original steps left onto the ledge and
        ; climbs; we were blocked and fell 57px to the floor.
        lbra ml_vertdone

; Common tail. Both buffers' damage-history sentinels are reset so the
; next two redraws do a full clear, instead of a small rect sized for the
; OLD room's Dizzy position, which would leave old-room pixels on screen.
;
; T0117: Dizzy's vertical state is NOT touched. This used to clear
; dizzy_dy and dizzy_floor ("re-settle from scratch"), so a jump that
; crossed a room edge lost the rest of its rise at the edge and fell from
; there -- playtest: "dizzy is not jumping high enough, or looses height on
; the jump in the transition", jumping from a high platform in one room to
; a higher one in the next. The original's goneleft/goneright change only
; x and goneup/gonedown only y; dy, floor and the animation carry straight
; on into the new room, and the next pass's collision scan handles
; whatever geometry is there.
rt_settle
        jsr set_checkpoint       ; T0050: enterroom's own checkpoint update
        jsr force_redraw       ; T0221 (was 8 bytes inline)
        rts

; room_exists: A = room number -> A != 0 if this build has that room's
; data. Reads the same table load_room does.
room_exists
        pshs x,u,b
        tfr a,b
        ldx #room_desc_table
rex_scan
        ldu ,x++
        cmpu #0
        beq rex_no
        cmpb ,u
        bne rex_scan
        puls b,u,x
        lda #1
        rts
rex_no
        puls b,u,x
        clra
        rts

rt_newroom  fcb 0
rt_arrive   fcb 0

; --------------------------------------------------------------------
; blit: draw a CoCo2-native monochrome bitmap onto the PMODE4 framebuffer.
; Parameters (set in memory by the caller before JSR):
;   blit_ptr = pointer to sprite data block (spr_N_w/h/bpr, then bitmap)
;   blit_x   = destination pixel_x (screen column, multiple of 4)
;   blit_y   = destination y (screen row, 0-191)
; Composites with OR (draws ink, never erases already-drawn ink) -- the
; original Z80 used a self-modified AND/XOR toggle keyed on frmreverse;
; OR-compositing is a deliberate simplification for this first slice (see
; NOTES.md "Slice: room 36") -- none of room 36's placements need to punch
; through each other, and it avoids replicating source self-modifying code
; for a target with no matching bit-plane need.
; --------------------------------------------------------------------
blit
        jsr tick_poll            ; T0051: keeps field_ctr honest across the
                                  ; frame -- blit is called from every draw
                                  ; phase, so this samples evenly
        pshs y                   ; T0052: callers (draw_actors) keep the
        ldy #nibswap+128          ; actor pointer in Y across this call
        lda blit_mirror          ; T0142: one-shot -- a caller sets it for
        sta bm_cur                ; ONE blit, exactly like a parameter, so a
        clr blit_mirror           ; stale flag can never leak into the next
        ldu blit_ptr
        ldb 1,u         ; height (skip width byte at 0,u)
        stb blit_rows

        ; T0067: VERTICAL CLIP. Nothing else stops a sprite whose bottom
        ; runs past row 191 from walking straight out of the bottom of
        ; the framebuffer and writing into whatever follows it -- gap1's
        ; dizzy frames and message VM after buffer A, the actor data
        ; after buffer B.
        ;
        ; Room 53 has had a 24-row sprite (frame 132) placed at y=176
        ; since the room was added: 8 rows off the bottom, every frame,
        ; the whole time. It was invisible because those 8 rows landed
        ; in the middle of some sprite's BITMAP, where a few corrupt
        ; bytes look like nothing. Growing the actor table (T0067) moved
        ; a sprite HEADER under the same address, so the same 8 rows
        ; started rewriting a width/height/bpr triple -- and the next
        ; blit through that header ran away across all of memory and
        ; took the machine down. The bug was three sessions old and only
        ; ever needed the memory behind it to be rearranged.
        ldb #192
        tst fb_flip              ; T0125: the flipped window ends at 184
        beq blit_bot
        ldb #FLIP_YEND
blit_bot
        stb blit_ybot
        lda blit_y
        cmpa blit_ybot
        lbhs blit_offscreen      ; starts below the last row: nothing to do
        adda blit_rows           ; bottom edge (y<=191, rows<=48: no carry)
        cmpa blit_ybot
        bls blit_rowsok
        lda blit_ybot
        suba blit_y
        sta blit_rows            ; only the rows that fit
blit_rowsok
        lda 2,u         ; bytes_per_row
        sta blit_bpr
        ldb #FBWIDTH    ; T0052: per-row dest advance, precomputed once --
        subb blit_bpr    ; both loops leave X exactly bpr bytes along
        jsr fb_strideb   ; T0125: -32-bpr when flipped
        stb blit_stride
        leau 3,u        ; U -> bitmap data start

        ; T0080: WINDOW TOP CLIP -- X-ALL.TXT's own `movestartdown`.
        ; A sprite starting above the window loses its top rows: the row
        ; count comes down and the SOURCE pointer walks forward by the
        ; same number of whole rows, so what lands at the window's top
        ; edge is the right slice of the bitmap rather than its start.
        ; `win_top` is a variable, not the constant, because draw_ui
        ; drops it to 0 while painting the banner -- the banner lives
        ; ABOVE the window by definition, and would otherwise clip
        ; itself out of existence.
        lda blit_y
        cmpa win_top
        bhs blit_topok
        lda win_top
        suba blit_y              ; rows above the window
        cmpa blit_rows
        lbhs blit_offscreen      ; all of it is above: nothing to draw
        pshs a
        lda blit_rows
        suba ,s
        sta blit_rows            ; only the rows inside the window
        puls a
        ldb blit_bpr
        mul                      ; D = skipped rows * bytes per row
        leau d,u                 ; ...walk the source past them
        lda win_top
        sta blit_y               ; and start at the window's top edge
blit_topok

        ; dest_col = pixel_x >> 3 ; shift = pixel_x & 4 (0 or 4)
        lda blit_x
        anda #$04
        sta blit_shift
        lda blit_x
        lsra
        lsra
        lsra
        sta blit_col

        ifne HCLIP
        ; T0211: HORIZONTAL CLIP. blit clipped vertically (above) but not
        ; horizontally, and the framebuffer is one flat 32-byte-per-row
        ; span -- so "past column 31" and "the left edge of the row below"
        ; are THE SAME ADDRESS. A sprite overrunning the right edge wrote
        ; its tail straight into the next row's first bytes.
        ;
        ; Rooms 22, 50, 51, 54, 57, 59, 67 and 68 each have a placement
        ; that overruns (room 54's worst: x=204 with an 80px sprite, so it
        ; ends at 284), so all eight have had stray wrapped pixels down
        ; their left edge for as long as they have existed. Found via
        ; a rejected framebuffer-scan mask experiment (NOTES.md T0208), which read the
        ; wrapped ink as solid, in exactly those rooms.
        ;
        ; The SHIFTED path touches one byte MORE than bpr -- its spill
        ; `sta ,x` writes at X+bpr without advancing X -- so it must stop
        ; a byte earlier. Consequence: a shifted sprite at col 31 clips
        ; away entirely (4px at the extreme right edge). The original
        ; clips at its window edge too, so that is acceptable.
        lda #FBWIDTH
        suba blit_col            ; dest bytes left in this row (1..32)
        tst blit_shift
        beq bhc_room
        deca                     ; shifted: reserve the spill byte
bhc_room
        ; Test A ITSELF -- not the flags left by `tst blit_shift`/`deca`.
        ; An earlier version branched on those and so threw away EVERY
        ; aligned blit (shift==0 sets Z, which `bls` also tests), drawing
        ; nothing at all. A cannot go negative here: blit_col is x>>3 on a
        ; byte, so it is at most 31 and A is at least 0 after the deca.
        tsta
        lbeq blit_offscreen      ; no room left at all
        cmpa blit_bpr
        bhs bhc_fits             ; the whole sprite fits -- the usual case
        sta blit_eff
        ldb blit_bpr
        subb blit_eff
        stb blit_srcskip         ; source bytes to skip at each row end
        bra bhc_stride
bhc_fits
        lda blit_bpr
        sta blit_eff
        clr blit_srcskip
bhc_stride
        ldb #FBWIDTH             ; recompute the per-row dest advance from
        subb blit_eff              ; the CLIPPED width, not bpr
        jsr fb_strideb           ; T0125: negated when flipped
        stb blit_stride
        endif

        ; row_addr = draw_base + y*32 + dest_col (draw_base: whichever
        ; buffer is currently off-screen -- see redraw)
        ldb blit_y
        jsr fb_rowd     ; D = draw_base + y*32 (T0125: row 231-y when flipped)
        tfr d,x
        ldb blit_col
        abx             ; X += dest_col (zero-extended byte add)

; T0052: X (dest) and U (source) now stay LIVE in registers for the whole
; sprite. They used to be reloaded from memory at the top of every row and
; stored back at the bottom -- ~82 cycles of pointer shuffling per row
; against 38-190 cycles of actual work, which for this port's sprites
; (2-4 bytes wide but 13-21 rows tall) was most of the routine. Both inner
; loops leave X exactly bpr bytes along and U at the next row's first
; source byte, so a row ends with one `abx` of the precomputed stride.
blit_rowlp
        tst bm_cur               ; T0142: X-ALL.TXT's own frmreverse -- one
        beq blit_rowgo            ; sprite serves both facings, instead of
        jsr blit_mkrev            ; storing a second, flipped copy of it
        pshs u                    ; (the packer cannot collapse those: a
        ldu #blit_revbuf          ; mirrored bitmap shares no byte runs
blit_rowgo                        ; with the sprite it came from)
        lda blit_shift
        bne blit_shifted

        ifne HCLIP
        ldb blit_eff             ; T0211: clipped width, not bpr
        else
        ldb blit_bpr
        endif
blit_alignedlp
        lda ,u+
        ora ,x
        sta ,x+
        decb
        bne blit_alignedlp
        bra blit_rowdone

blit_shifted
        ; source byte's high nibble ORs into the current dest byte's low
        ; nibble; its low nibble ORs into the next dest byte's high one.
        ; B has to hold the source byte for the table lookups, so the row
        ; is bounded by comparing U against its own end instead.
        tfr u,d                  ; X is untouched by this -- no save needed
        ifne HCLIP
        addb blit_eff            ; T0211: clipped width, not bpr
        else
        addb blit_bpr
        endif
        adca #0
        std blit_rowend
blit_shiftedlp
        ldb ,u+
        lda b,y                  ; Y = nibswap+128, set at blit entry
        anda #$0f                ; = s >> 4
        ora ,x
        sta ,x+
        lda b,y
        anda #$f0                ; = (s & $0F) << 4
        ora ,x
        sta ,x
        cmpu blit_rowend
        bne blit_shiftedlp

blit_rowdone
        tst bm_cur               ; T0142: back to the real bitmap, one row on
        ifne HCLIP
        bne bd_mirrored
        ldb blit_srcskip         ; T0211: the loop consumed only blit_eff
        leau b,u                   ; source bytes -- step over the clipped
        bra blit_rowadv            ; tail so U lands on the next row
bd_mirrored
        puls u
        ldb blit_bpr             ; revbuf always holds a FULL row
        leau b,u
        else
        beq blit_rowadv
        puls u
        ldb blit_bpr
        leau b,u
        endif
blit_rowadv
        ldb blit_stride
        leax b,x                 ; T0125: signed (-32-bpr when flipped)
        dec blit_rows
        bne blit_rowlp

        puls y                   ; T0052
        rts

; Entirely below the last row: nothing to draw. Placed AFTER blit's own
; rts on purpose. The SHIFTED row path falls through into blit_rowdone,
; so an early-out sitting in front of that label is not an early-out at
; all -- it is a one-row blit, which is exactly what it was: every
; 4px-shifted sprite drew its top row and returned.
blit_offscreen
        puls y                   ; blit pushed Y on entry
        rts

; --------------------------------------------------------------------
; blitdizzy: draw Dizzy's own sprite (real mask+sprite planes, unlike the
; single-plane background objects `blit` handles). Fixed 24px/3-byte-wide
; source. Composites as the original does: screen = (screen AND mask) XOR
; sprite -- mask=1 preserves the existing screen bit there, mask=0 forces
; it to 0 first (a "punch clear, then draw" hole); sprite bit then XORs
; in the actual ink. mask=1 + sprite=0 in the padding areas outside the
; sprite's real shape is what gives true transparency.
;
; T0018: handles the same two horizontal alignments `blit` does for
; placements -- byte-aligned (dizzy_x mod 8 == 0) and a 4-pixel nibble
; shift (dizzy_x mod 8 == 4) -- NOT arbitrary 1px shifts. dizzy_x is
; always rounded down to a multiple of 4 (only bit 2 of the low byte is
; consulted for the shift decision; bits 0-1 are ignored). This matches
; the same "4-pixel unit" granularity the room-placement coordinate
; system already uses (NOTES.md "Correction #2") -- a deliberate,
; consistent tradeoff across the whole renderer, not a shortcut unique to
; Dizzy. True 1px movement would need a full 0-7 shifter; not attempted
; here since AND/XOR compositing (unlike `blit`'s plain OR) requires
; explicit "preserve" padding at both shifted edges, which only the two
; cases below are implemented for.
;   dizzy_x = destination left edge, dizzy_y = destination FEET (bottom
;   edge, matching the original -- see FLOOR_Y/NOTES.md); the actual
;   top row is computed here as dizzy_y minus the current frame's own
;   height, looked up via dizzy_ff, so shorter frames don't float.
; --------------------------------------------------------------------
blitdizzy
        ; look up this frame's height from the redesigned frame set
        ; (newdz_heights, indexed by dizzy_ff -- see newdizzy_frames.asm)
        ldb dizzy_ff
        ldx #dizzy_frame_heights
        abx
        lda ,x
        sta bd_height

        lda dizzy_y
        suba bd_height
        sta bd_toprow

        ; T0081: WINDOW TOP CLIP for Dizzy. blitdizzy is its own masked
        ; compositor and never goes through `blit`, so T0080's clip
        ; missed him entirely -- which is how his sprite ended up drawn
        ; across the banner. Same shape as blit's: drop the rows above
        ; the window, and walk BOTH source pointers (mask and sprite,
        ; 3 bytes per row each in either loop) past them below.
        clr bd_skip
        lda bd_toprow
        cmpa win_top
        bhs bd_topok
        lda win_top
        suba bd_toprow           ; rows above the window
        cmpa bd_height
        lbhs bd_alldone          ; all of him is above it: draw nothing (long: T0125)
        sta bd_skip
        lda bd_height
        suba bd_skip
        sta bd_height            ; only the rows inside the window
        lda win_top
        sta bd_toprow            ; ...starting at its top edge
bd_topok
        ; T0125: flipped, the window ends at 184 (Dizzy's feet reach 188 at
        ; the bottom transition), and both row strides go negative.
        ldb #FBWIDTH-3
        jsr fb_strideb
        stb bd_str3
        ldb #FBWIDTH-4
        jsr fb_strideb
        stb bd_str4
        tst fb_flip
        beq bd_nobot
        lda #FLIP_YEND
        suba bd_toprow
        bls bd_alldone          ; starts at/below row 184: nothing inside
        cmpa bd_height
        bhs bd_nobot
        sta bd_height            ; only the rows above 184
bd_nobot

        ldb bd_toprow
        jsr fb_rowd             ; D = draw_base + top_row*32 (T0125: mirrored)
        tfr d,x

        lda dizzy_x
        anda #$04
        sta bd_shift
        lda dizzy_x
        lsra
        lsra
        lsra                    ; a = x / 8 (byte column)
        tfr a,b
        abx
        stx bd_row

        ; mask/sprite pointer tables are 16-bit entries, so index by
        ; dizzy_ff*2 (newdz_maskptrs/spriteptrs -- newdizzy_frames.asm)
        ldb dizzy_ff
        aslb
        ldx #dizzy_frame_maskptrs
        abx
        ldu ,x
        stu bd_maskptr
        ldx #dizzy_frame_spriteptrs
        abx
        ldu ,x
        stu bd_spriteptr

        lda bd_skip              ; T0081: skip the clipped rows' source
        beq bd_noskip
        ldb #3                   ; 3 bytes per row, both planes
        mul
        addd bd_maskptr
        std bd_maskptr
        lda bd_skip
        ldb #3
        mul
        addd bd_spriteptr
        std bd_spriteptr
bd_noskip

        ; T0064: ONE loop per shift case, with X/U/Y live across rows.
        ; This used to reload the destination pointer, the mask pointer
        ; and the sprite pointer from memory at the top of every row,
        ; write two of them back at the bottom, recompute the row
        ; address from scratch, and re-test the (loop-invariant) shift --
        ; about 65 cycles of bookkeeping per row against 21 rows, every
        ; frame. The compositing itself is untouched: both bodies below
        ; are the original ones, moved rather than rewritten.
        lda bd_height
        sta bd_rows
        ldx bd_row
        ldu bd_maskptr
        ldy bd_spriteptr
        lda bd_shift
        bne bd_shiftedlp
        bra bd_alignedlp
bd_alldone
        rts

bd_alignedlp
; --- byte-aligned: 3 dest bytes, direct AND/XOR, no padding needed ---
        lda ,x
        anda ,u+
        eora ,y+
        sta ,x+
        lda ,x
        anda ,u+
        eora ,y+
        sta ,x+
        lda ,x
        anda ,u+
        eora ,y+
        sta ,x+
        ldb bd_str3              ; X is 3 bytes along -- step to the next row
        leax b,x                 ; (T0125: signed)
        dec bd_rows
        bne bd_alignedlp
        rts

bd_shiftedlp
        lda ,u+
        sta bd_m0
        lda ,u+
        sta bd_m1
        lda ,u+
        sta bd_m2

        lda ,y+
        sta bd_s0
        lda ,y+
        sta bd_s1
        lda ,y+
        sta bd_s2

        ; dest byte 0: mask = $F0 | (m0>>4), sprite = (s0>>4)
        lda bd_m0
        lsra
        lsra
        lsra
        lsra
        ora #$f0
        sta bd_tm
        lda bd_s0
        lsra
        lsra
        lsra
        lsra
        sta bd_ts
        lda ,x
        anda bd_tm
        eora bd_ts
        sta ,x+

        ; dest byte 1: mask = (m0<<4)|(m1>>4), sprite = (s0<<4)|(s1>>4)
        lda bd_m0
        asla
        asla
        asla
        asla
        sta bd_tm
        lda bd_m1
        lsra
        lsra
        lsra
        lsra
        ora bd_tm
        sta bd_tm
        lda bd_s0
        asla
        asla
        asla
        asla
        sta bd_ts
        lda bd_s1
        lsra
        lsra
        lsra
        lsra
        ora bd_ts
        sta bd_ts
        lda ,x
        anda bd_tm
        eora bd_ts
        sta ,x+

        ; dest byte 2: mask = (m1<<4)|(m2>>4), sprite = (s1<<4)|(s2>>4)
        lda bd_m1
        asla
        asla
        asla
        asla
        sta bd_tm
        lda bd_m2
        lsra
        lsra
        lsra
        lsra
        ora bd_tm
        sta bd_tm
        lda bd_s1
        asla
        asla
        asla
        asla
        sta bd_ts
        lda bd_s2
        lsra
        lsra
        lsra
        lsra
        ora bd_ts
        sta bd_ts
        lda ,x
        anda bd_tm
        eora bd_ts
        sta ,x+

        ; dest byte 3 (trailing edge): mask = (m2<<4)|$0F, sprite = (s2<<4)
        lda bd_m2
        asla
        asla
        asla
        asla
        ora #$0f
        sta bd_tm
        lda bd_s2
        asla
        asla
        asla
        asla
        sta bd_ts
        lda ,x
        anda bd_tm
        eora bd_ts
        sta ,x+

        ldb bd_str4              ; the shifted path wrote 4 bytes
        leax b,x                 ; (T0125: signed)
        dec bd_rows
        lbne bd_shiftedlp
        rts

placeptr   fdb 0

blit_ptr    fdb 0
rat_sv_col    rmb 1      ; T0052 save-under scratch
rat_sv_w      rmb 1
rat_sv_h      rmb 1
rat_sv_rows   rmb 1
rat_sv_stride rmb 1
blit_rowend   rmb 2      ; T0052: end of the current source row
blit_rows     rmb 1      ; T0052: rows left in this sprite
blit_stride   rmb 1      ; T0052: FBWIDTH - bpr, the per-row dest advance
nib_tmp       rmb 1      ; T0052: scratch for the boot-time table build
blit_x      fcb 0
blit_y      fcb 0
; T0080: blit's top clip edge. WINDOW_TOP for everything in the room;
; draw_ui drops it to 0 around the banner, which lives above the window.
win_top     fcb WINDOW_TOP
; T0125: the upside-down world. `upsidedown` is X-ALL.TXT's own flag (only
; the well traversal changes it); fb_flip is what the drawing primitives
; obey, copied from it by redraw every pass and cleared by msg_begin -- the
; source's prtmessage unflips around every box (flipifnecessary).
upsidedown  fcb 0
fb_flip     fcb 0
blit_ybot   fcb 192
cb_ybot     fcb 192
bd_str3     fcb FBWIDTH-3
bd_str4     fcb FBWIDTH-4

; Every primitive tests fb_flip directly (Z clear = mirrored): a call per
; test cost ~0.5 passes/sec in every room. draw_ui clears it while it paints
; the banner, which is outside the window.

; fb_rowd: B = logical row -> D = draw_base + row*32, the row mirrored to
; FLIP_SUM-row when flipped. Leaves X, Y, U alone.
fb_rowd
        tst fb_flip
        beq fbr_n
        negb
        addb #FLIP_SUM
fbr_n   lda #FBWIDTH
        mul
        addd draw_base
        rts

; fb_strideb: B = the downward per-row stride (32-width) -> the stride to
; use: unchanged, or B-64 (= -32-width) when flipped, walking UP a row.
fb_strideb
        tst fb_flip
        beq fbs_x
        subb #64
fbs_x   rts
blit_bpr    fcb 0
        ifne HCLIP
blit_eff    fcb 0      ; T0211: bytes actually written per row (<= bpr)
blit_srcskip fcb 0     ; T0211: source bytes clipped off each row
        endif
blit_col    fcb 0
blit_shift  fcb 0

draw_base     fdb BUFB   ; first redraw() draws into B (cur_buf starts at 0/A)
cur_buf       fcb 0      ; 0 = buffer A currently on screen, 1 = buffer B
prof_slot     fcb 0      ; T0064: phase id, tapped by harness/profile.lua
field_ctr     fcb 0      ; T0051: 60Hz field boundaries seen since the last
                          ; page flip -- see tick_poll/wait_vsync

; damage-rect redraw state (see redraw) -- 255 sentinel means "this
; buffer has never been drawn into", forcing one full-screen redraw
; the first time each buffer is used.
bufA_last_x   fcb 255
bufA_last_y   fcb 0
bufB_last_x   fcb 255
bufB_last_y   fcb 0
old_dizzy_x   fcb 0
old_dizzy_y   fcb 0
bd_skip       fcb 0      ; T0081: blitdizzy rows clipped off above the window
pre_y         fcb 0      ; T0081: feet y before the vertical scan's lift
new_col       fcb 0
old_col       fcb 0
dmg_col0      fcb 0
dmg_col1      fcb 0
dmg_y0        fcb 0
dmg_y1        fcb 0
clr_row       fcb 0

keyflags      fcb 0
lives         fcb 2       ; spare lives (eggs shown); new_game sets it
coins         fcb 0

; T0023: active-room indirection (see load_room)
cur_room           fcb 36
room_load_seq      fcb 0       ; T0123: bumped by every load_room
; T0067: these fields are copied AS ONE BLOCK by load_room out of
; the room's `room_desc` record (emitted by roompack). Their order and
; adjacency are part of that contract -- nothing may be inserted between
; them, and if the record changes, both ends change together.
room_place_count   fcb 0
room_placements_ptr fdb 0
room_placements_end fdb 0    ; T0064: one past the last placement
room_place_bands_ptr fdb 0   ; T0064: 12-entry y-band start index
; T0166: room_cmask_ptr REMOVED -- CUR_ROOM_CMASK is derived in place at
; every load_room (derive_room_cmask), so there is no per-room pointer to
; carry. This record is one field shorter than before Change 1.
room_flame_count   fcb 0     ; T0026: torch flames
room_flames_ptr    fdb 0
room_flame_tab_ptr fdb 0
room_water_count   fcb 0
room_water_ptr     fdb 0
room_water_tab_ptr fdb 0
ROOM_DESC_LEN      equ *-room_place_count

flame_ctr          fcb 0       ; 16-step animation counter (as the original)
flame_n            fcb 0
flame_ptr          fdb 0
water_ctr          fcb 0       ; 4-step ripple counter
water_n            fcb 0
water_ptr          fdb 0
flame_spr          fdb 0
flame_var          fcb 0
fireout            fcb 0    ; T0032 follow-up: matches the original's own
                             ; `fireout` global exactly -- gates room 2's
                             ; fire-pit overlay, set by gameplay.asm

; clear_and_blit's shared scratch -- one set, reused by draw_flames,
; draw_actors and draw_water rather than each keeping its own copy.
cb_spr             fdb 0
cb_force           fcb 0    ; 1 = redraw regardless of the damage-rect test
cb_col0            fcb 0
cb_col1            fcb 0
cb_ry0             fcb 0
cb_ry1             fcb 0
; Which animation variant is currently rendered in each buffer -- 255 =
; unknown, forcing a draw the first time each buffer is used.
flame_var_a        fcb 255
flame_var_b        fcb 255
fire_var_a         fcb 255
fire_var_b         fcb 255
cb_x               fcb 0
cb_y               fcb 0
clr_width          fcb 0    ; T0064: prime-clear width/stride, hoisted
clr_stride         fcb 0    ; out of the row loop
cb_width           fcb 0    ; T0064: clear width/stride, hoisted out
cb_stride          fcb 0    ; of clear_and_blit's row loop
cb_rows            fcb 0
rat_lastx_a        fcb 255   ; last x the rat was drawn at, per buffer --
rat_lastx_b        fcb 255   ; 255 = never drawn in that buffer yet

dizzy_x       fcb 0
dizzy_y       fcb 0       ; feet (bottom edge), not top -- see FLOOR_Y
dizzy_dy      fcb 0       ; signed vertical velocity
dizzy_floor   fcb 0       ; 1 = resting on solid ground
dizzy_dir     fcb 0       ; direction 0=none,1=left,2=right (latched off the floor, T0136)
jump_on       fcb 0       ; T0136: a jump sequence is running (original sequence>=3)
jump_anim     fcb 0       ; T0136: the original's 8-step animation within that jump
dizzy_seq     fcb 0       ; 0-5, see dizzy_seqtab
dizzy_anim    fcb 0       ; 0-7, cycles regardless of movement (idle blink)
anim_div      fcb 0       ; ANIM_DIVIDER-frame divider gating dizzy_anim
dizzy_ff      fcb 0
dizzy_h       fcb 21      ; current frame's height (feet-anchored maths)
probe_x       fcb 0       ; collision probe scratch
probe_y       fcb 0
try_x         fcb 0       ; candidate x for check_wall
vstep         fcb 0       ; per-pixel vertical step counter       ; resolved sprite frame id (0-38)
bd_toprow     fcb 0
bd_height     fcb 0
bd_row        fdb 0
bd_maskptr    fdb 0
bd_spriteptr  fdb 0
bd_rows       fcb 0    ; T0064: blitdizzy's row countdown
bd_shift      fcb 0
bd_m0         fcb 0
bd_m1         fcb 0
bd_m2         fcb 0
bd_s0         fcb 0
bd_s1         fcb 0
bd_s2         fcb 0
bd_tm         fcb 0
bd_ts         fcb 0

; sequence x animation -> frame id, recovered exactly from X-ALL.TXT's
; seq0-seq5 tables (NOTES.md "Recover: Dizzy's own movement/physics/
; collision/animation"). sequence = (airborne?3:0) + direction(0/1/2).
; REVERTED back to the real extracted frame set (NOTES.md "back to the
; Spectrum translation, round 2") after the redesigned art proved the
; rendering pipeline itself is clean -- the bug is somewhere in this
; real data specifically.
dizzy_seqtab
        fcb 0,1,0,1,0,1,0,1         ; seq0: idle (2-frame blink)
        fcb 9,10,11,12,13,14,15,16  ; seq1: walk left
        fcb 17,18,19,20,21,22,23,24 ; seq2: walk right
        fcb 2,3,4,5,6,7,8,1         ; seq3: jump, no direction
        fcb 25,26,27,28,29,30,31,9  ; seq4: jump left
        fcb 32,33,34,35,36,37,38,17 ; seq5: jump right
        fcb 4,5,5,6,6,5,5,4         ; seq6: bob upside down (the source's
                                     ; own comment) -- unused so far, but
                                     ; the table has to stay dense for the
                                     ; seq*8 index, and it is 8 bytes
        fcb 0,1,8,8,7,6,7,7         ; seq7: fall over backwards -- the
                                     ; DEATH animation (T0059)
        fcb 8,7,6,5,4,3,2,1         ; seq8: upside-down tumble (T0125, the well)

; T0025's self-test message (all prtmessage opcodes exercised at once)
; was verified via capture long ago and cost 131 bytes doing nothing
; else -- removed to reclaim headroom, now down to single digits below
; the framebuffer. If the message VM needs a regression fixture again,
; NOTES.md's T0025 section has the exact byte stream and the capture
; that confirmed it.

        ; T0058: rooms 36 and 35's art relocated to $0100.
        ;
        ; That range used to be the staging area for the $8000+ rooms
        ; and is free now that staging moved into framebuffer A (see the
        ; staged block at the end of this file). It is ordinary loadable
        ; RAM from $0100 (the stack lives BELOW it, growing down from
        ; $0100 through $0000) up to `start:` at $0E00, and these two
        ; files are pure data reached only by absolute address, so they
        ; are free to sit there.
        ;
        ; Worth ~1.6KB of headroom in the $0E00-$4000 region, which this
        ; task had squeezed down to SIX bytes before dizzy_frame35 would
        ; have started overwriting framebuffer A -- the same corruption
        ; that once cost a session to diagnose (see dizzy_frames_all.asm's
        ; own header).
low_resume equ *
        org $0100
        include "room36_data.asm"
        include "room35_data.asm"
        ; T0071: gap_messages.asm moved HERE from the $5800 gap -- that
        ; gap was down to 28 bytes free (the dragon's own new messages
        ; alone need more than that), while this $0100 region still had
        ; over 1.6KB spare. Pure data reached only by absolute `ldx
        ; #label`, so where it lives is arbitrary; this is just the
        ; region with room left.
        include "gap_messages.asm"
        include "ui_room_names.asm"
        ; T0081: ui.asm moved here too. T0080's window clip plus this
        ; task's Dizzy clip and climb refusal pushed the $0E00-$4000
        ; code region 15 bytes past $4000, into framebuffer A's staging
        ; block -- caught by memaudit's cross-block overlap check (T0075),
        ; which is exactly the silent-corruption class it was added for.
        ; ui.asm is pure code+data reached only by absolute jsr/ldx, so
        ; where it lives is arbitrary; this region still had ~1KB spare.
        include "ui.asm"
        ; T0104: boot-only code (the LZSS unpacker and the START_ITEM
        ; inventory seeder) moved here for the same reason ui.asm was --
        ; T0103's actor collision pushed $0E00-$4000 past its end.
        include "boot_code.asm"
; T0124: THE GUARD THIS REGION NEVER HAD. It ends where `start:` begins, and
; nothing checked that: moving Armorog's code here and adding the lifts made
; it 3459 bytes, 131 of them over $0E00, and the only sign was memaudit's
; overlap report (start:'s own first 131 bytes overwritten at load).
low_region_end equ *
        ifgt low_region_end-$0E00
        error "low region ($0100-$0DFF) overflows into start: at $0E00"
        endif
        org low_resume
        ; (sound_data.asm moved with it -- see the note above)
        include "actors.asm"
        include "gameplay.asm"
        if TAPE_ROOMS
code_data_end equ *             ; T0223: end of the resident $0E00-$4000 block (title hole 1 starts here at the earliest)
        endif
        ; T0107: the main body of Dizzy's animation frames STAGED to
        ; $8000+ (r9800 block, see below) -- it was the single biggest
        ; occupant of this code+data region, 4125 bytes (measured via
        ; lwasm's own listing, NOTES.md). Pure data reached only through
        ; dizzy_frame_maskptrs/spriteptrs/heights, the same shape room
        ; data already has, so the move costs no code change: those
        ; pointer tables resolve to the final $8000+ addresses because
        ; the block is `phase`d, exactly like every staged room's own
        ; labels. The file's small resident TAIL (frame36 on, split out
        ; long before this task -- see dizzy_frames_tail.asm's own
        ; header) is unaffected and stays right here.
        include "dizzy_frames_tail.asm"

        ; Pure data (no code, no internal branches -- everything below
        ; is only ever reached via an absolute `ldx #label`/`lda label`,
        ; which works from anywhere) relocated into the 2K gap between
        ; the two PMODE4 framebuffers ($4000-$57FF and $6000-$77FF) --
        ; genuinely unused RAM under the CURRENT SAM setup, no banking
        ; or "all-RAM mode" reconfiguration needed. The $0E00-$4000
        ; range was getting critically tight (down to single digits of
        ; headroom at one point) purely because everything had been
        ; piling up below the framebuffer instead of using this gap.
        ;
        ; No `org $5800` here anymore -- dizzy_frames_all.asm's own
        ; tail (frame36 on) now carries an internal org into this same
        ; gap (see its own comment), so the address counter is already
        ; sitting here by the time this line is reached; these three
        ; just continue sequentially right after it.
        include "message.asm"    ; T0051: moved out of the $0E00-$4000
                                  ; region, which the pacing polls left with
                                  ; 50 bytes of headroom. Pure code, reached
                                  ; only by absolute jsr, so it runs the same
                                  ; from here.
        ; T0218b: font_data.asm and sound_data.asm now live in the STAGED
        ; code block (search code_staged_end below). They were the port's
        ; last entirely-raw blobs of any size; moving them into a block that
        ; unpack_d already delivers converts ~1045 raw load-file bytes into
        ; ~726 packed ones, worth +296 to the delivery budget. Nothing new was
        ; needed: no extra stream, no mktitle flag, no new unpack routine.
        ; actor_data.asm used to sit here too, but T0048/T0049 (wiring
        ; room 52's removable railing and room 53's gator/rock/whiskey)
        ; grew it by four sprites and left this gap with 43 bytes to
        ; spare -- too thin to be safe. Moved down to the $7800 block
        ; below, which had over a kilobyte free. Pure data referenced
        ; only by absolute `ldx #label`, so where it lives is arbitrary.

        ; T0033 follow-up/memory audit: shared_sprites_data.asm (the
        ; T0035 cross-room sprite dedup, 1109 bytes) doesn't fit ALSO
        ; squeezed into the $5800 gap above -- confirmed the hard way,
        ; not guessed: an earlier attempt to fit it there overflowed
        ; past $6000 into the LIVE framebuffer B, and a separate attempt
        ; to also move font/actor/room2 in alongside it overflowed a
        ; combined block past $8000 into ROM. Gets its OWN org into a
        ; SEPARATE, previously entirely unused 2KB block at
        ; $7800-$7FFF, right after framebuffer B and before $8000 where
        ; ROM starts on both the 32K and 64K CoCo2 -- ordinary always-
        ; mapped RAM on the base 32K address range every CoCo2 has, no
        ; SAM all-RAM/banking reconfiguration needed, same "genuinely
        ; unused gap" reasoning as $5800 above. Confirmed the active
        ; stack pointer sits at ~$03D3 at runtime, nowhere near either
        ; block, before relying on either.
        ; T0123: actor_data.asm moved again, into the packed $8000 image (see the
        ; r8000 block): this gap was down to 18 bytes and Armorog's sprites
        ; need more. Nothing reads actor data before boot has unpacked the
        ; image (actors_init runs in new_game, after show_title).
        ; T0124: and the emptied gap takes the per-room behaviour routines
        ; (Armorog, the lifts): the $0100 low region they first went into
        ; overflowed into start:, and code+data is full.
        if TAPE_ROOMS
gap1_end equ *                  ; T0221: end of the $5800 block (TAPE_LOW_REGION2 starts here)
        endif
        org $7800
        include "logic_low.asm"
gap2_end equ *
        if TAPE_ROOMS
        ifgt gap2_end-$7F00
        error "the $7800 gap (room behaviour code) runs into nibswap at $7F00"
        endif
        else
        ifgt gap2_end-$7E00
        error "the $7800 gap (room behaviour code) runs into nibswap at $7E00"
        endif
        endif
        ; shared_sprites_data.asm used to sit here too. T0058 moved it up
        ; into the $8000 block, because the four sprites the crocodile
        ; needed (frame 124 plus three mirrors, 192 bytes) pushed its
        ; tail from $7E00 into `nibswap` -- which is built at boot and
        ; therefore ATE the last few hundred bytes of it, giving `blit` a
        ; garbage width/height header and a machine that reset itself
        ; about a second after boot. The DECB block list is what showed
        ; it (block 7800-7EE0 against `org $7E00 nibswap`); no symbol
        ; check would have, since the overrun is data past the last
        ; label. Check `lwasm` block extents, not just symbols.

        ; T0041/T0036: room 52 (THE ENTRANCE HALL) and room 53 (SNAP
        ; HAPPY GATOR), both living at $8000+ (SAM all-RAM mode) -- see
        ; NOTES.md and the relocate copy loop in start:. Physically
        ; loaded here at $0100 (an ordinary low-memory CLOADM
        ; destination, since BASIC's loader can't write $8000+ directly
        ; -- see the copy loop's own comment for why), but PHASE makes
        ; every label inside resolve to its real, final $8000+ address,
        ; so load_room's lr_room52/lr_room53 references above compile
        ; correctly without needing to know about the staging step at
        ; all. ONE phase block, not two -- room 53's labels continue
        ; wherever room 52's left off, and the copy loop below moves
        ; both in a single pass since they're physically contiguous
        ; here too.
        ;
        ; Both self-contained -- no --shared-sprites -- deliberately.
        ; The two 2KB gaps above needed cross-room sprite dedup because
        ; they were desperately short on space; up here there's ~32KB
        ; free, so the dedup complexity buys nothing and just adds a
        ; dependency on shared_sprites_data.asm's own ordering.
        ;
        ; Staging capacity, not the $8000+ destination, is what
        ; actually limits how much can be staged at once: everything
        ; here has to fit below start:'s own $0E00 (T0036 moved the
        ; stack to a fixed low $0100 specifically to free up more of
        ; that space -- see start:'s own comment). Room 52 alone
        ; (1451 bytes) fit in the old $0500-$0E00 window; room 52 +
        ; room 53 together (2873 bytes) doesn't, which is the actual
        ; reason that move happened, not a hypothetical.
        ; T0052: blit's nibble-swap table. Ordinary RAM in the $7800 gap
        ; -- deliberately NOT up at $8000+, so the core blitter never
        ; depends on all-RAM mode being real on hardware. `rmb` reserves
        ; the space without putting 256 bytes in the load file; start:
        ; fills it in at boot.
        ; T0052 scratch RAM, all of it inside the $7800 gap. NOTE the
        ; addresses: nibswap+256 and the save blocks must all stay BELOW
        ; $8000, which is where the relocated room 52/53 data lives. An
        ; earlier version of this put nibswap at $7F00, which pushed the
        ; save buffers to $8000 and straight through room 52's sprites.
        if TAPE_ROOMS
        ; T0225b (L2'): the TAPE build moves nibswap to the very top of the gap ($7F00-$7FFF,
        ; so TAPE_LOW_REGION is contiguous up to it) and the rat save-under buffers out of
        ; here entirely, into the title's transient tail (see RAT_SV_* after T0163_SCRATCH_END).
        ; nibswap itself cannot go transient: it is built once at boot and the game-over
        ; title replay would clobber it.
        org $7F00
nibswap rmb 256
        else
        org $7E00
nibswap rmb 256
        ; T0052 rat save-under: 5-byte header (valid, addr, w, h) then the
        ; saved bytes, one block per framebuffer.
rat_sv_hdr_a rmb 5
rat_sv_buf_a rmb RAT_SV_CAP
rat_sv_hdr_b rmb 5
rat_sv_buf_b rmb RAT_SV_CAP
        endif

        if STAGE_LZ
; T0085 -- the SAME two blocks, LZSS-packed. Generated; do not hand-edit.
;
; The destination image is unchanged, so nothing that references a
; staged label needs to know. staged_syms.asm supplies those labels as
; absolute equs taken from the raw pass's map, which works only because
; the blocks are PHASEd to absolute $8000: their addresses do not move
; when resident code changes size. Verified in the raw pass -- every
; symbolic operand inside the staged data resolves to another staged
; label, so the image contains no pointers into resident code that
; adding this unpacker could invalidate.
;
; The two blocks are packed SEPARATELY, one per window, not as a single
; stream. A single stream is 86 bytes smaller but cannot be decoded:
; the windows are not contiguous ($5800-$5FFF between them holds the
; dizzy frame tail, the message VM and the font), so a source pointer
; walking off the end of A would read resident data as compressed bytes.
; T0231-fix: TAPE_ROOMS builds must NEVER reuse the -run build's staged
; artifacts -- staged_syms.asm/staged_a_lz.asm/staged_b_lz.asm are
; addresses+bytes measured against ONE specific resident-code layout
; (the RAW pass that produced them), and resident code size now differs
; between TAPE_ROOMS=0/1 (this task's own show_title_resident et al).
; tools/stage_pack.sh runs its ENTIRE pipeline twice, once per value,
; writing "_tape"-suffixed files for TAPE_ROOMS=1 so the two builds'
; artifacts can never cross-contaminate. See NOTES.md T0231.
        if TAPE_ROOMS
        if FLOPPY
        include "staged_syms_floppy.asm"
        else
        include "staged_syms_tape.asm"
        endif
        else
        include "staged_syms.asm"
        endif
        org $4000
r8000_staged_start
        if TAPE_ROOMS
        if FLOPPY
        include "staged_a_lz_floppy.asm"
        else
        include "staged_a_lz_tape.asm"
        endif
        else
        include "staged_a_lz.asm"
        endif
r8000_staged_end
        if TAPE_ROOMS
        ifgt r8000_staged_end-TAPE_START_ORG
        error "staged block A runs into tape start: -- lower TAPE_START_ORG (and check start: still ends by $5800)"
        endif
        endif
        org $6000
r9800_staged_start
        if TAPE_ROOMS
        if FLOPPY
        include "staged_b_lz_floppy.asm"
        else
        include "staged_b_lz_tape.asm"
        endif
        else
        include "staged_b_lz.asm"
        endif
r9800_staged_end
        else
; T0058: staged at $4000 -- inside framebuffer A -- not at $0100.
;
; The staging area only has to be (a) somewhere BASIC's CLOADM can
; write, and (b) untouched between load and the relocate loop in
; `start:`, which runs before anything draws. Framebuffer A satisfies
; both and is 6KB, where $0100 had 228 bytes left: rooms 52+53 alone
; reached $0D1C and `start:` begins at $0E00.
;
; That 228 bytes is what made this necessary. room2_data.asm had been
; quietly overflowing the $5800 gap by ~220 bytes INTO framebuffer B --
; assembled fine, loaded fine, and the audit missed it for the reason
; the audit note in regen_art.sh now warns about a second time: room 2's
; last LABEL sits at $5F61, below $6000, while its data runs on to
; $60D9. Only a listing shows that; a symbol scan never will. Moving
; room 2 up here fixes the overflow and leaves the $5800 gap with real
; headroom again.
        org $4000
r8000_staged_start
        phase $8000
        ; T0235: every base room below that lives in these staged blocks
        ; (NOT room36/room35, which live at $0100 outside this mechanism
        ; entirely, and NOT room2, which has no room_desc_table entry --
        ; see NOTES.md T0235) gets a TAPE_ROOMS-only duplicate include,
        ; the same pattern frame_table_data_tape.asm/actor_data_tape.asm
        ; already use: roomNN_data_tape.asm is generated by its own
        ; regen_art.sh invocation with --pack-room-data (falls back to
        ; raw per-room if packing loses, roompack's own decision -- see
        ; tools/roompack/src/main.rs), so the -run build's own
        ; roomNN_data.asm (included in the `else` branch) is completely
        ; untouched and room36.bin stays byte-identical. Shrinking these
        ; rooms' RAW size (this raw pass, STAGE_GEN) moves IMAGE_END
        ; down and grows the tape-only room region below -- the point of
        ; this round; see NOTES.md T0235 for the measured net.
        if TAPE_ROOMS
        include "room52_data_tape.asm"
        else
        include "room52_data.asm"
        endif
        if TAPE_ROOMS
        include "room53_data_tape.asm"
        else
        include "room53_data.asm"
        endif
        if TAPE_ROOMS
        include "room69_data_tape.asm"
        else
        include "room69_data.asm"
        endif
        include "room2_data.asm"
        if TAPE_ROOMS
        include "room67_data_tape.asm"    ; T0084 -- 1574 bytes, fits A's spare
        else
        include "room67_data.asm"    ; T0084 -- 1574 bytes, fits A's spare
        endif
        if TAPE_ROOMS
        include "room84_data_tape.asm"    ; T0094 -- 1309 bytes, into T0085's headroom
        else
        include "room84_data.asm"    ; T0094 -- 1309 bytes, into T0085's headroom
        endif
        if TAPE_ROOMS
        include "room85_data_tape.asm"    ; T0094 -- 1331 bytes
        else
        include "room85_data.asm"    ; T0094 -- 1331 bytes
        endif
        if TAPE_ROOMS
        include "room83_data_tape.asm"    ; T0120 -- 1062 bytes standalone
        else
        include "room83_data.asm"    ; T0120 -- 1062 bytes standalone
        endif
        if TAPE_ROOMS
        include "room86_data_tape.asm"    ; T0120 -- 309
        else
        include "room86_data.asm"    ; T0120 -- 309
        endif
        if TAPE_ROOMS
        include "room70_data_tape.asm"    ; T0120 -- 97, EMPTY: 86 -> 70 -> 54 fall
        else
        include "room70_data.asm"    ; T0120 -- 97, EMPTY: 86 -> 70 -> 54 fall
        endif
        if TAPE_ROOMS
        include "room50_data_tape.asm"    ; T0123 -- 636 raw (shared pool reused)
        else
        include "room50_data.asm"    ; T0123 -- 636 raw (shared pool reused)
        endif
        if TAPE_ROOMS
        include "room71_data_tape.asm"    ; T0124 -- 754 raw
        else
        include "room71_data.asm"    ; T0124 -- 754 raw
        endif
        if TAPE_ROOMS
        include "room57_data_tape.asm"    ; T0159 -- BASE OF TREE HOUSE, 408 raw, no actors
        else
        include "room57_data.asm"    ; T0159 -- BASE OF TREE HOUSE, 408 raw, no actors
        endif
        if TAPE_ROOMS
        include "room72_data_tape.asm"    ; T0161 -- DENZIL'S PAD, 475 raw, 2 actors + 1 coin
        else
        include "room72_data.asm"    ; T0161 -- DENZIL'S PAD, 475 raw, 2 actors + 1 coin
        endif
        if TAPE_ROOMS
        include "room58_data_tape.asm"    ; T0??? -- THE SMELLY ALLOTMENT, 885 raw standalone, 2 pickupable actors
        else
        include "room58_data.asm"    ; T0??? -- THE SMELLY ALLOTMENT, 885 raw standalone, 2 pickupable actors
        endif
        if TAPE_ROOMS
        include "room59_data_tape.asm"    ; T0??? -- THE LARGE OAK TREE, 1423 raw standalone, 2 pickupable actors + 1 coin
        else
        include "room59_data.asm"    ; T0??? -- THE LARGE OAK TREE, 1423 raw standalone, 2 pickupable actors + 1 coin
        endif
        if TAPE_ROOMS
        include "room60_data_tape.asm"    ; T0??? -- BASE OF THE VOLCANO, 1197 raw standalone, 2 pickupable actors
        else
        include "room60_data.asm"    ; T0??? -- BASE OF THE VOLCANO, 1197 raw standalone, 2 pickupable actors
        endif
        include "shared_sprites_data.asm"
        ; T0233-fix: TAPE_ROOMS gets its OWN frame_table_data_tape.asm --
        ; a superset of frame_table_data.asm (same prefix, so every -run
        ; index still resolves identically) plus entries for the 18
        ; tape-only rooms' own sprites. Growing the ORIGINAL file would
        ; change block A's raw bytes for BOTH builds (T0231's own
        ; coupling class); this file only exists inside the tape
        ; build's own independent pass. See tools/regen_art.sh's own
        ; note and NOTES.md T0233.
        if TAPE_ROOMS
        include "frame_table_data_tape.asm"
        else
        include "frame_table_data.asm"     ; T0167: global room_placements index table
        endif
        include "shared_anim_data.asm"     ; T0121: the one copy of the flame/water tiles
        include "actor_data.asm"          ; T0123: actor table, sprites, coins
        include "dizzy_frames_bodyA.asm"
        dephase
r8000_staged_end

; T0067: a SECOND staging block, through framebuffer B.
;
; The four neighbour rooms took the $8000 image past 11.5KB, and one
; staging window is only as big as one framebuffer (6KB). Framebuffer B
; is free at load time for exactly the same reason A is -- nothing draws
; until after the relocate in `start:` -- so it carries the rest. The
; two blocks must NOT be one contiguous org: the $5800 gap between the
; buffers holds real resident data (the dizzy frame tail, the message
; VM, the font), and a block spanning it would overwrite that.
;
; The destination follows straight on from block 1, computed rather than
; hardcoded, so moving a room between the blocks needs no arithmetic by
; hand.
R9800_DEST   equ $8000+(r8000_staged_end-r8000_staged_start)
        org $6000
r9800_staged_start
        phase R9800_DEST
        if TAPE_ROOMS
        include "room51_data_tape.asm"
        else
        include "room51_data.asm"
        endif
        if TAPE_ROOMS
        include "room54_data_tape.asm"
        else
        include "room54_data.asm"
        endif
        if TAPE_ROOMS
        include "room68_data_tape.asm"
        else
        include "room68_data.asm"
        endif
        if TAPE_ROOMS
        include "room55_data_tape.asm"
        else
        include "room55_data.asm"
        endif
        ; T0123: 100 and 87 moved here from block A to balance the two windows
        if TAPE_ROOMS
        include "room100_data_tape.asm"   ; T0120 -- 1000
        else
        include "room100_data.asm"   ; T0120 -- 1000
        endif
        if TAPE_ROOMS
        include "room87_data_tape.asm"    ; T0122 -- 648 raw (shared pool reused)
        else
        include "room87_data.asm"    ; T0122 -- 648 raw (shared pool reused)
        endif
        if TAPE_ROOMS
        include "room56_data_tape.asm"    ; T0124 -- 681 raw
        else
        include "room56_data.asm"    ; T0124 -- 681 raw
        endif
        if TAPE_ROOMS
        include "room24_data_tape.asm"    ; T0159 -- INSIDE THE CHURCH, 387 raw
        else
        include "room24_data.asm"    ; T0159 -- INSIDE THE CHURCH, 387 raw
        endif
        if TAPE_ROOMS
        include "room22_data_tape.asm"    ; T0162 -- THE MARKET SQUARE, no actors
        else
        include "room22_data.asm"    ; T0162 -- THE MARKET SQUARE, no actors
        endif
        if TAPE_ROOMS
        include "room76_data_tape.asm"    ; T0222 -- measuring per-room cost
        else
        include "room76_data.asm"    ; T0222 -- measuring per-room cost
        endif
        include "shared_sprites_overflow_data.asm"
        include "dizzy_frames_bodyB.asm"
        dephase
r9800_staged_end

; T0125: a THIRD block, the image's tail. Both framebuffer windows are full
; (39 + 23 took B 394 bytes over), so this one is not staged in RAM that the
; game later draws over: tools/stage_pack.sh takes these raw bytes from this
; pass (org $E000 here is only a place to assemble them), and mktitle packs
; them into the title's load-time holes after the music (--extra). new_game
; unpacks them to RC_DEST (logic_low.asm unpack_c).
RC_DEST      equ R9800_DEST+(r9800_staged_end-r9800_staged_start)
        org $E000
rc_staged_start
        phase RC_DEST
        if TAPE_ROOMS
        include "room39_data_tape.asm"    ; T0125 -- GOING DOWN THE WELL
        else
        include "room39_data.asm"    ; T0125 -- GOING DOWN THE WELL
        endif
        if TAPE_ROOMS
        include "room23_data_tape.asm"    ; T0125 -- A STRANGE NEW WORLD
        else
        include "room23_data.asm"    ; T0125 -- A STRANGE NEW WORLD
        endif
        dephase
rc_staged_end
        endif

; T0107 scratch buffers -- resolved HERE, after the branch above closes,
; so both sides agree on the one thing that matters: "the address right
; after all staged room data, in the real $8000+ image". Cannot be
; resolved INSIDE the if/else -- see BANNER_BYTES' own comment above for
; why that was tried and got the packed branch wrong.
        if STAGE_LZ
; T0231-fix: same reasoning as staged_syms.asm above -- IMAGE_END is
; measured from the RAW pass, which now differs by TAPE_ROOMS.
        if TAPE_ROOMS
        if FLOPPY
        include "image_end_lz_floppy.asm"
        else
        include "image_end_lz_tape.asm"
        endif
        else
        include "image_end_lz.asm"   ; IMAGE_END equ, from stage_pack.sh,
                                      ; computed from the RAW pass's real
                                      ; sizes -- the only place that
                                      ; number still exists once packing
                                      ; has happened
        endif
        else
IMAGE_END     equ RC_DEST+(rc_staged_end-rc_staged_start)   ; T0125: block C is the tail
        endif
; T0121: the scratch chain above the room image, laid out by LIFETIME.
;
;   BANNER_BUF     the in-game banner art, 1536    PERMANENT
;   TITLE_RAW_BUF  TRANSIENT space, used in turn by:
;                    the 3-voice mixer blob + its DP page (only while the
;                    title is up), and
;                    CUR_ROOM_CMASK (only while a game is running)
;
; What it replaced (T0092..T0120) kept every one of those in its OWN area --
; a 4096-byte gather gap, the banner overwriting the packed stream (so game
; over had to keep the UNPACKED title instead: 6144 more bytes), the mask
; after that with $200 of slack, then the mixer and its page -- ~13.9KB, and
; by T0120 only ~750 bytes of room image could still be added before the
; mixer's page reached $FF00. This is ~11.6KB and the same three guards.
;
; T0147: TITLE_RAW_BUF no longer holds the unpacked title image at all.
; show_title unpacks the packed title straight into framebuffer B
; ($6000-$77FF, idle while the title is up on A) and transposes from there
; into framebuffer A. That dropped TITLE_RAW_BUF's job from "unpacked
; title, then mixer blob, then room mask" to just "mixer blob, then room
; mask" -- 6144 bytes shrank to whichever of those two is bigger (the
; mixer, with its DP page: TITLE_MUSIC_RAW+256, see TITLE_RAW_LEN below).
;
; T0146: TITLE_LZ_BUF (the gathered packed title+music+block C stream) has
; LEFT this chain entirely -- it used to be PERMANENT because game over
; re-entered show_title (show_title_again) to redisplay the title, so the
; packed source had to survive the whole game. Game over now shows a text
; screen (update_death's msg_gameover) instead of the title, so show_title
; is genuinely boot-only: TITLE_LZ_BUF is defined below as framebuffer A
; ($4000) itself, which show_title drains (title image, mixer blob, block
; C's room data) and then overwrites with the finished title before boot
; ever falls into new_game. See boot_code.asm's show_title header and
; logic_low.asm's unpack_c header for the sequencing that makes this safe.
;
; Why sharing TITLE_RAW_BUF is safe: nothing that uses it is ever alive at
; the same time as anything else that does. The mixer unpacks into it while
; the title is up (the image is in the framebuffers by then, not here any
; more), then new_game's load_room refills the room mask over the mixer.
; Between boot and the first new_game nothing reads the mask.
;
; lz_unpack may read one flags byte past the end of a stream, so the gather
; area (TITLE_LZ_BUF/framebuffer A, 6144 bytes, comfortably bigger than the
; ~3.8KB stream) keeps slack after it; that byte is only READ. (title_
; frags.asm, which defines TITLE_LZ_LEN/TITLE_MUSIC_LEN/_RAW, is written by
; mktitle AFTER stage_pack's first assembly pass, which must still assemble
; with an older one -- hence the fallbacks.)
        ifndef TITLE_MUSIC_LEN
TITLE_MUSIC_LEN equ 1024
        endif
        ifndef TITLE_MUSIC_RAW
TITLE_MUSIC_RAW equ 3072         ; > the real ~2.9KB
        endif
        ifndef TITLE_EXTRA_LEN
TITLE_EXTRA_LEN equ 1024         ; first build after T0125 only
        endif
        ifndef TITLE_EXTRA2_LEN
TITLE_EXTRA2_LEN equ 512         ; T0148: first build only, before mktitle has run
        endif
TITLE_GATHER_LEN equ TITLE_LZ_LEN+TITLE_MUSIC_LEN+TITLE_EXTRA_LEN+TITLE_EXTRA2_LEN+8   ; T0125: + block C, T0148: + block D (code)
; T0146: TITLE_LZ_BUF is framebuffer A itself, not part of the downward
; chain below -- boot-transient, drained and overwritten before new_game.
TITLE_LZ_BUF  equ $4000
        ifgt TITLE_GATHER_LEN-6144
        error "the gathered title+music+block-C stream no longer fits framebuffer A"
        endif
; T0145: the chain is anchored at the TOP of RAM and laid out DOWNWARD, not
; upward from IMAGE_END. Same three buffers in the same order; the only
; difference is WHERE THE SLACK LANDS. Built upward, the leftover sat at
; $EFCC-$FEFF where nothing could ever use it -- 3892 bytes stranded above
; the last buffer. Built downward, that same slack lands directly above
; IMAGE_END, which is exactly where the room image grows.
; T0147: sized for the bigger of the mixer blob (its own DP page must be
; a WHOLE page, so it needs TITLE_MUSIC_RAW rounded up to a page boundary
; plus one more full page) and CUR_ROOM_CMASK (CMASK_BYTES, 384) -- the
; mixer wins by a wide margin, but the CMASK_BYTES guard below keeps that
; true rather than assumed.
TITLE_RAW_LEN equ TITLE_MUSIC_RAW+256   ; mixer blob + its DP page
TITLE_RAW_BUF equ $FF00-TITLE_RAW_LEN   ; transient -- see above
; T0237: TAPE_ROOMS drops the resident banner copy entirely -- draw_ui no
; longer repaints from it (ui.asm) and boot_code.asm's ti_transpose no
; longer writes it (show_title/show_title_resident's own T0237 comments),
; now that rd_cleardmg's real clobber is clamped instead. BANNER_BUF
; aliases TITLE_RAW_BUF (unused, but keeps the symbol defined for any
; code that still names it) and CODE_DEST rises by BANNER_BYTES. The
; -run build (else) is UNCHANGED.
        if TAPE_ROOMS
BANNER_BUF    equ TITLE_RAW_BUF
        else
BANNER_BUF    equ TITLE_RAW_BUF-BANNER_BYTES   ; T0146: now the floor of the chain
        endif
; T0148: resident CODE staged to $8000+, exactly like room data already is
; (NOTES.md "the relief valve nobody had tried"). Placed at the TOP of the
; room-growth span, immediately below BANNER_BUF, and growing DOWNWARD --
; so the gap between IMAGE_END and here stays one contiguous span for
; future room data, the same reasoning T0145 gave for anchoring the whole
; scratch chain at the top instead of the bottom. CODE_BUDGET (defined
; early in this file, before the STAGE_LZ branch) is the fixed reservation;
; the STAGE_GEN branch's guard on code_staged_end-code_staged_start is what
; keeps the real block from silently outgrowing it.
CODE_DEST     equ BANNER_BUF-CODE_BUDGET
; T0166 (Change 1, delivery half): CUR_ROOM_CMASK is now the ONLY mask
; buffer -- derive_room_cmask clears it and rasterises straight into it
; (there is nothing left to compare it against at runtime; that proof
; already happened offline, tools/derive_cmask.py, and online while the
; stored mask still shipped, harness/cmaskverify.lua's git history). Live
; only during a game, same as the old T0106 stored-mask buffer it
; replaces -- same address, same lifetime.
CUR_ROOM_CMASK equ TITLE_RAW_BUF
ATTR_CELLS_W  equ 32                  ; 256/8: pass-1 "decorative" cell grid
ATTR_CELLS_H  equ 24                  ; 192/8
; ONE BYTE per cell here (768 bytes), not bit-packed: a plain row*32+col
; address needs no bit-shift/bittab machinery at either of this array's
; two call sites (dc_attr_write's write, dc_pass2_place's test) -- the
; code-size difference is what let this fit the delivery budget at all
; (T0163). RAM is not the scarce resource here (see the comment above
; CUR_ROOM_CMASK).
ATTR_CELLS_LEN equ ATTR_CELLS_W*ATTR_CELLS_H   ; 768
ATTR_CELLS    equ CUR_ROOM_CMASK+CMASK_BYTES
; T0163: room_placements now ships in SOURCE order (roompack); the y-sorted
; copy + 16px band index redraw_placements_dmg still needs (T0064) is built
; into RAM here at every room load instead (rd_sortplaces), from that same
; source table. ROOM_PLACE_MAX must exceed the biggest built room's
; placement count -- 95 (room 72) as of T0163; kept with headroom.
ROOM_PLACE_MAX equ 128
ROOM_PLACE_SORTED equ ATTR_CELLS+ATTR_CELLS_LEN
ROOM_PLACE_BANDS  equ ROOM_PLACE_SORTED+(ROOM_PLACE_MAX*4)
T0163_SCRATCH_END equ ROOM_PLACE_BANDS+(12*2)
        ifgt T0163_SCRATCH_END-(TITLE_RAW_BUF+TITLE_RAW_LEN)
        error "T0163's derive/sort scratch no longer fits the shrunken transient title buffer"
        endif
; T0225b (L2'): TAPE build -- the rat/hawk/Dozy save-under buffers (2 x (5 + RAT_SV_CAP) =
; 234 B) live in the gameplay-unused tail of this chain, above the scratch tables. They are
; CLOBBERED by every title run (mixer blob/DP page); that is safe because they are
; designed for garbage: new_game clears both valid bytes right after force_redraw, and
; redraw's 255-sentinel path (rat_sv_invalidate) drops each buffer's slot before its
; first rat_restore. Only the title (boot, game-over and win replays) can clobber them and
; every title run is followed by `jmp new_game`.
        if TAPE_ROOMS
rat_sv_hdr_a equ T0163_SCRATCH_END
rat_sv_buf_a equ rat_sv_hdr_a+5
rat_sv_hdr_b equ rat_sv_buf_a+RAT_SV_CAP
rat_sv_buf_b equ rat_sv_hdr_b+5
RAT_SV_END   equ rat_sv_buf_b+RAT_SV_CAP
        ifgt RAT_SV_END-(TITLE_RAW_BUF+TITLE_RAW_LEN)
        error "the save-under buffers no longer fit the gameplay-unused tail of the title scratch chain"
        endif
        endif
MIX3_BUF      equ TITLE_RAW_BUF      ; mixer blob: live during the title only
; the first WHOLE page past the blob (T0120: rounding DOWN once put the
; page inside the blob and wiped the tail of its event stream)
MIX3_DP       equ (MIX3_BUF+TITLE_MUSIC_RAW+255)/256
        ifgt (MIX3_BUF+TITLE_MUSIC_RAW)-(MIX3_DP*256)
        error "MIX3_DP's page overlaps the unpacked mixer blob"
        endif
        ifgt (MIX3_DP*256+256)-(TITLE_RAW_BUF+TITLE_RAW_LEN)
        error "MIX3_DP's page runs past the shrunken transient title buffer"
        endif
        ifgt CMASK_BYTES-TITLE_RAW_LEN
        error "CUR_ROOM_CMASK no longer fits the shrunken transient title buffer"
        endif
        ifgt IMAGE_END-BANNER_BUF
        error "the room image grew up into the title scratch chain -- no room left above IMAGE_END"
        endif
        ; T0148: the tighter bound -- CODE_DEST sits BELOW BANNER_BUF now,
        ; so it, not BANNER_BUF, is the real ceiling for room growth.
        ifgt IMAGE_END-CODE_DEST
        error "the room image grew up into the staged resident code block below the title scratch chain"
        endif

; T0148: a FOURTH staged block -- not room data, RESIDENT CODE
; (update_dragon + dragon_flames, gameplay.asm's per-room actor update for
; room 54's dragon). Proves the staging mechanism generalises. Delivered
; the same way block C is -- packed into the title's load-time holes --
; but as its OWN stream (mktitle's --extra2), not appended to block C's:
; concatenating would force it to decode contiguously with RC_DEST, which
; is the opposite end of the free span from where T0148 places it.
;
; NOT phased like block C: `org CODE_DEST` DIRECTLY (no scratch org, no
; phase/dephase). Block C and rooms 52/53 etc. can use phase safely
; because they are pure DATA -- no relative addressing anywhere inside
; them. This block has BRANCHES, and lwasm 4.24 miscomputes relative
; offsets inside a phased block whenever the physical org differs from the
; phase target (see target/dragon_code.asm's own header for the repro and
; the harness that caught it -- it assembles clean either way, wrongly,
; and only an emulator check that pokes the routine's own state proved
; it). Assembling straight at the real address sidesteps the bug
; entirely, and costs nothing here: this whole STAGE_GEN raw pass is never
; loaded on real hardware (same as block C's own $E000 scratch org note).
;
; Has to live HERE, after CODE_DEST (and so BANNER_BUF, and so the
; STAGE_LZ if/else above) is resolved -- unlike RC_DEST, CODE_DEST is not
; computable INSIDE that if/else (same reason IMAGE_END/BANNER_BUF cannot
; be, see their own comment above). In the packed pass (STAGE_LZ=1) the
; block is never assembled at all -- staged_syms.asm supplies
; `update_dragon equ CODE_DEST` directly, the same way it supplies every
; other label inside the packed room image.
        if STAGE_LZ
        ifndef update_dragon
        error "staged_syms.asm did not define update_dragon -- rerun tools/stage_pack.sh, never assemble -DSTAGE_LZ=1 by hand"
        endif
        ifndef update_crocodile
        error "staged_syms.asm did not define update_crocodile -- rerun tools/stage_pack.sh, never assemble -DSTAGE_LZ=1 by hand"
        endif
        ifndef update_portcullis
        error "staged_syms.asm did not define update_portcullis -- rerun tools/stage_pack.sh, never assemble -DSTAGE_LZ=1 by hand"
        endif
        else
        org CODE_DEST
code_staged_start
        include "dragon_code.asm"
        ; T0161: same staged block, same org run -- see
        ; croc_portcullis_code.asm's own header for why these two join
        ; update_dragon here rather than getting a block of their own.
        include "croc_portcullis_code.asm"
        ; T0162: same staged block, same org run -- see
        ; rat_troll_hazard_code.asm and armorog_lifts_dagger_code.asm's
        ; own headers for why this batch joins update_dragon here
        ; rather than getting a block of their own.
        include "rat_troll_hazard_code.asm"
        include "armorog_lifts_dagger_code.asm"
        include "font_data.asm"
        include "sound_data.asm"
code_staged_end
        ifgt (code_staged_end-code_staged_start)-CODE_BUDGET
        error "the staged dragon/crocodile/portcullis code block outgrew its CODE_BUDGET reservation"
        endif
        endif

; T0230: TAPE-ONLY ROOM REGION -- proving step for tape-delivered rooms.
;
; Lives in [IMAGE_END, CODE_DEST), the free span above the packed/staged
; room image (blocks A/B/C) and below the staged resident code block
; (block D), unconditional on STAGE_LZ (both passes reach the same
; IMAGE_END/CODE_DEST, see their own comments above) but gated entirely
; on TAPE_ROOMS: the -run build (TAPE_ROOMS=0, the default) never
; assembles this block at all, so room36.bin does not change size or
; shape and rooms 74/75 do not exist in it, not even unreachable --
; ABSENT from room_desc_table (see above) and the image.
;
; Unlike blocks A-D this data is delivered RAW, at its real final
; address, directly by target/tape_stage1.asm's existing addr>=$8000
; segment path (T0228/T0229) -- no framebuffer staging, no LZ pack, no
; title-hole gather. `org IMAGE_END` is the real physical address here
; (no `phase` needed, same reasoning as block D's `org CODE_DEST`
; directly above): IMAGE_END is already >=$8000, so what lwasm assembles
; here IS the final address, byte for byte.
;
; tools/tape_pack.sh assembles a SEPARATE full image (target/
; room36_tape.bin) via its OWN complete run of tools/stage_pack.sh
; (TAPE_ROOMS=1, writing "_tape"-suffixed artifacts -- staged_syms_tape.asm,
; image_end_lz_tape.asm, title_frags_tape.asm/title_lz_tape.asm, staged_a/
; b_lz_tape.asm) so NOTHING here is measured against the -run build's
; resident-code layout. T0231's own bug (staged code calling/reading
; resident addresses that had shifted between the two builds, because the
; tape build used to reuse the -run build's staged_syms.asm etc.) is why
; this is a hard rule now: never reuse one build's staged artifacts in
; another build. This block (rooms 74/75 + the title-resident copy) is
; still the only SOURCE difference between the two; the artifact-sharing
; is what changed.
        if TAPE_ROOMS
        org IMAGE_END
tape_room_staged_start
        ; T0231: the resident copy of the packed title-image+music stream
        ; (tools/mktitle --resident-out), for the game-over title replay
        ; (boot_code.asm's show_title_resident). Placed first so it never
        ; moves as rooms are appended after it.
        if FLOPPY
; T0241: the floppy build keeps NO resident copy of the title stream (OVL_TITLE on disk instead);
; only its length constant is needed (generated, tools/stage_pack.sh), then the disk driver and
; the overlay loader take the start of this region.
        include "title_resident_len_floppy.asm"
        include "floppy_code.asm"
        include "floppy_leftclip.asm"     ; T0261: run-time left clip of partly-off-screen placements
        else
        include "title_resident_lz.asm"
        endif
        ; T0234: the tape-only region's OWN actor table -- ACTOR_*_tape/
        ; actor_init_tape/actor_spr_tab_tape, entirely independent of
        ; actor_data.asm's ACTOR_*/actor_init above (both builds' own,
        ; per tools/regen_art.sh's --actor-suffix note). Placed here,
        ; before any room, so it never moves as rooms are appended.
        ; This table IS the live, mutable RAM record for these actors --
        ; unlike actor_data.asm (copied ROM->RAM at boot, boot_code.asm),
        ; this region is delivered raw at its real final address with no
        ; relocation at all (T0230's own reasoning), so the assembled
        ; fcb bytes already sit in real R/W RAM once tape-loaded, and no
        ; separate copy step is needed. Known limitation, not fixed this
        ; round: a picked-up/moved tape actor does NOT reset on a fresh
        ; game after a game over within the same tape session (no ROM
        ; template survives to restore from) -- see NOTES.md T0234.
        include "actor_data_tape.asm"
        ; T0236: the tape-only region's own SECOND coin table
        ; (coin_init_tape, coin_init_tape_template) -- same coupling
        ; class as actor_data_tape.asm just above (COIN_STRIDE_tape/
        ; COIN_COUNT_tape/coin_init_tape, tools/roompack's --coin-suffix/
        ; --coins-only). 15 entries: 12 in tape-only rooms whose
        ; cointable entry (X-ALL.TXT, 30 total) falls there, plus 3
        ; (rooms 22/67/76) that are base rooms but were never carried
        ; into the RESIDENT coin_init -- see coin_data_tape.asm's own
        ; header and NOTES.md T0236 for why that's out of scope here.
        include "coin_data_tape.asm"
        ; T0236: daisyrou1's ending text (msg_notgotallcoins/
        ; msg_gotallcoins) -- see msg_data_tape.asm's own header for why
        ; this is a plain, hand-written include here rather than living
        ; in a DTE source (target/text_src/gameplay.asm).
        include "msg_data_tape.asm"
        ; T0227: tape_code.asm moved to TAPE_LOW_REGION3 (below) -- the tape-only region has
        ; to hold the room-94 dagger/carpet records, and code does not care where it lives.
        ; T0235: per-room LZ pack -- the fixed unpack buffer load_room
        ; unpacks EVERY packed room's placements+flames+water into
        ; (room36.asm's load_room, gated `if TAPE_ROOMS`), sized to the
        ; largest packed room's raw byte total (roompack's --pack-room-
        ; data emits an assemble-time `ifgt ROOM_RAW_LEN-ROOM_UNPACK_BUF_
        ; LEN error` per room against this same constant, so a room that
        ; outgrows it fails the build instead of corrupting the next
        ; room's data at runtime). `fill`, not `rmb` -- T0172's own
        ; reasoning just above (rmb here would split the tape image into
        ; two DECB segments and leave this buffer's bytes as whatever the
        ; loader found in RAM, which cur_room's very first load_room call
        ; overwrites anyway, but a split segment is the real risk, not
        ; the content). Placed here, before any packed room's data, so it
        ; never moves as rooms are appended. ROOM_UNPACK_BUF_LEN itself is
        ; defined much earlier in this file (next to RELOC_BOOT_BYTES) --
        ; every packed base room's own `ifgt` guard (block A/B/C, staged
        ; well before this point) needs it in scope, and lwasm's `ifgt`
        ; needs a value it can resolve on the pass it's read, not a
        ; forward reference the way an ordinary operand can be.
ROOM_UNPACK_BUF
        fill 0,ROOM_UNPACK_BUF_LEN
        include "room74_data.asm"     ; T0230 -- THE GIANT BEANSTALK, 58+16
        include "room75_data.asm"     ; T0230 -- COMPLEX CLOUD ROUTE, 59+16
        ; T0233: the rest of the vertical slice's walkable rooms, added
        ; smallest/most-connected first per the brief, until the region
        ; is full. Room 77 (THE ACTIVE VOLCANO) is NOT here: a
        ; pre-existing roompack limitation blocks it (see
        ; tools/regen_art.sh's own note, NOTES.md T0233). T0234: rooms
        ; 40/45/73/88/89/93 now have their SAFE pickupable actors wired
        ; (actor_data_tape.asm above) -- everything else in every one of
        ; these rooms' "things" (extracted/rooms.json) still renders as
        ; inert static scenery, per T0233's own note below.
        include "room63_data.asm"     ; T0233 -- THE CRAFTY CLOUD
        include "room91_data.asm"     ; T0233 -- YET MORE CLOUDS
        include "room92_data.asm"     ; T0233 -- MORE 'ORRIBLE CLOUDS
        include "room45_data.asm"     ; T0233 -- LOOKING OUT TO SEA
        include "room48_data.asm"     ; T0233 -- THE BROKEN BRIDGE
        include "room49_data.asm"     ; T0233 -- THE GUARD HOUSE
        include "room94_data.asm"     ; T0233 -- DAISY'S PRISON
        include "room89_data.asm"     ; T0233 -- DIZZY'S PARENTS' HUT
        include "room41_data.asm"     ; T0233 -- THE DESERTED MINES
        include "room73_data.asm"     ; T0233 -- DAISY'S EMPTY HUT
        include "room88_data.asm"     ; T0233 -- LIFT TO THE ELDERS
        include "room93_data.asm"     ; T0233 -- THE CLOUD CASTLE
        include "room40_data.asm"     ; T0233 -- THE DRAGON'S LAIR
        include "room46_data.asm"     ; T0233 -- THE DOCKS AND PIER
        include "room31_data.asm"     ; T0233 -- THE AMAZING ILLUSION
        include "room47_data.asm"     ; T0233 -- FOURWAY WAREHOUSE
        include "room77_data.asm"     ; T0233-fix -- THE ACTIVE VOLCANO
        ; T0240: joy_walk (the analog joystick's main-loop half; code in the tape-only tail)
        include "tape_joy_code.asm"
        if FLOPPY
CLIPBUF rmb CLIP_BUF_LEN          ; T0261: bss, cropped sprites of the current room (floppy_leftclip.asm)
        endif
tape_room_staged_end
        ifgt tape_room_staged_end-CODE_DEST
        error "the tape-only room region overlaps CODE_DEST -- shrink it or grow the free span"
        endif
        ; IMAGE_END overlap is impossible by construction (org starts
        ; AT IMAGE_END, never before it), but pin it anyway: a future
        ; edit that moves the org above could silently open a gap
        ; tape_pack.sh's segment extraction would get wrong.
        ifne tape_room_staged_start-IMAGE_END
        error "tape-only room region does not start exactly at IMAGE_END"
        endif
        endif

; T0219: TAPE_LOW_REGION -- PERSISTENT tape-only storage below $8000.
;
; [TAPE_LOW_START, TAPE_LOW_END) = gap2: from the end of the $7800 block
; (logic_low.asm, gap2_end) up to nibswap at $7E00. In the tape build it
; used to hold title fragment 5; the title+music stream is now de-
; duplicated (boot copies it from TITLE_RESIDENT_LZ, boot_code.asm), so
; nothing is loaded here and the window is free for future tape-only
; content: data/code placed here is delivered by an ordinary direct (below
; $8000) tape segment, and NOTHING overwrites it at boot or at runtime --
; verified against the memory map: the title gather writes only
; TITLE_LZ_BUF ($4000-$57FF) and unpacks through $6000-$77FF; nibswap
; ($7E00) and the rat save-under ($7F00) sit above TAPE_LOW_END.
;
; RULES for putting something here: (1) it must be assembled between
; tape_low_slot_start and tape_low_slot_end below (this `org` slot -- the
; assemble-time guard fails the build if it outgrows TAPE_LOW_END);
; (2) the tape build only (everything here is gated TAPE_ROOMS; the -run
; build is byte-identical without it); (3) tools/tape_pack.sh keeps
; tape_stage1 out of this window and HARD-FAILS if any tape segment
; overlaps stage1; (4) never end above $7E00. The slot is EMPTY today.
        if TAPE_ROOMS
TAPE_LOW_START equ gap2_end
TAPE_LOW_END   equ nibswap       ; T0225b: $7F00 now (nibswap moved up, rat_sv left the gap)
        org TAPE_LOW_START
tape_low_slot_start
        ; T0220: Dozy's first-talk conversation (DTE, encode-only source
        ; target/text_src_tape/msg_data_tape_low.asm)
        include "msg_data_tape_low.asm"
        ; T0221: the win boxes + completion tune; sizes of the blob in
        ; TAPE_LOW_REGION2 (generated by tools/stage_pack.sh)
        if FLOPPY
        include "win_mix3_syms_floppy.asm"
        else
        include "win_mix3_syms.asm"
        endif
        include "tape_win_code.asm"
        include "tape_talk_code.asm"      ; T0229: Dylan/Doug talk dispatch
tape_low_slot_end
        ifgt tape_low_slot_end-TAPE_LOW_END
        error "the tape-only low region (TAPE_LOW_REGION) runs into nibswap at $7F00"
        endif
        ifne tape_low_slot_start-TAPE_LOW_START
        error "tape low region slot does not start at TAPE_LOW_START"
        endif
        ; T0219: boot copies TITLE_RESIDENT_LZ to the start of the gathered
        ; stream and gathers only block C/D after it, so the resident blob
        ; must be EXACTLY the title+music prefix of that stream.
        ifne TITLE_RESIDENT_LEN-(TITLE_LZ_LEN+TITLE_MUSIC_LEN)
        error "TITLE_RESIDENT_LZ is not exactly the title+music prefix of the gathered title stream"
        endif
        endif

; T0221: TAPE_LOW_REGION2 -- gap1, [gap1_end, $6000): the second PERSISTENT
; tape-only region below $8000 (798 B in the current layout). Since T0219 it
; is no title hole and tape_stage1 is not in it. Loaded by an ordinary direct
; tape segment, written by nothing afterwards (the framebuffer windows are
; $4000-$57FF and $6000-$77FF; the $5800 block ends at gap1_end).
; Holds the completion tune's LZ-packed mixer blob (win_mix3_lz.asm, generated
; by tools/stage_pack.sh) and nothing else. Same rules as TAPE_LOW_REGION:
; tape build only, content between the slot labels, guard against the end.
        if TAPE_ROOMS
TAPE_LOW2_START equ gap1_end
TAPE_LOW2_END   equ $6000
        org TAPE_LOW2_START
tape_low2_slot_start
        if FLOPPY
        include "win_mix3_lz_floppy.asm"
        else
        include "win_mix3_lz.asm"
        endif
tape_low2_blob_end
        ; T0240: joy_fire (scankeys' tail: joystick buttons = SPACE)
        include "tape_joy_fire.asm"
tape_low2_slot_end
        ifgt tape_low2_slot_end-TAPE_LOW2_END
        error "the completion-tune blob (TAPE_LOW_REGION2) runs into framebuffer B at $6000"
        endif
        ifne tape_low2_blob_end-tape_low2_slot_start-WIN_MIX3_LZ_LEN
        error "win_mix3_lz.asm is not WIN_MIX3_LZ_LEN bytes"
        endif
        endif

; T0223/T0224: TAPE_LOW_REGION3 -- [code_data_end, $4000): everything between
; the end of the resident $0E00-$4000 block and framebuffer A. Third PERSISTENT
; tape-only region below $8000.
;
; T0224: this used to be only the unused TAIL of title hole 1 (the front of the
; hole held block C+D's packed stream for boot's gather). Blocks C and D now
; travel as RAW tape segments at RC_DEST / CODE_DEST, nothing is gathered, so
; the whole span is free: the region STARTS at code_data_end itself (no
; mktitle-emitted start any more). Nothing at boot or runtime writes it: the
; gather target is TITLE_LZ_BUF ($4000+), the unpack scratch is $6000-$77FF,
; the stack is at $0100 and every rmb of the resident block is a mapped symbol
; below code_data_end. It moves 1:1 with resident code size -- use labels,
; never addresses. In the raw measurement pass (STAGE_GEN) the slot is parked
; at $c400 so it cannot pollute the raw image.
        if TAPE_ROOMS
TAPE_LOW3_START equ code_data_end
TAPE_LOW3_END   equ $4000
        ifdef STAGE_GEN
        org $c400
        else
        org TAPE_LOW3_START
        endif
tape_low3_slot_start
        ; T0223: shopkeeper -> bean -> plant -> water -> beanstalk (cdt_shop,
        ; cdt_tape, update_shop, tape_room_hook, stalk placements)
        include "tape_bean_code.asm"
        ; T0226: door knocker, empty-bucket fill, pickaxe + rock
        include "tape_item_code.asm"
        ; T0227: moved here from the tape-only region (T0239 put it there)
        include "tape_code.asm"
        ; T0228: Daisy in room 94 (meeting) + the heart demo (also the win sequence's tail)
        include "tape_daisy_code.asm"
        ; T0240: joy_read + variables (the analog joystick; see tape_joy_code.asm)
        include "tape_joy_read.asm"
tape_low3_slot_end
        ifndef STAGE_GEN
        ifgt tape_low3_slot_end-TAPE_LOW3_END
        error "TAPE_LOW_REGION3 content runs past $4000 (framebuffer A): resident code grew into it"
        endif
        endif
        endif

; T0224: TAPE_LOW_REGION4 -- [low_region_end, $0E00): the old title hole 0, the
; spare at the top of the $0100 low block, below `start:`. Fourth PERSISTENT
; region below $8000 (EMPTY today). Delivered by an ordinary direct segment;
; nothing writes it at boot or runtime (the stack is $0000-$00FF and the low
; block ends at low_region_end by its own guard). Starts at the end of the low
; block's code, so it moves with that block (boot_code.asm / ui.asm / messages).
; Same rules as the other regions: tape build only, content between the slot
; labels, guard against the end. Parked at $c800 in the raw pass.
        if TAPE_ROOMS
TAPE_LOW4_START equ low_region_end
TAPE_LOW4_END   equ $0E00
        ifdef STAGE_GEN
        org $c800
        else
        org TAPE_LOW4_START
        endif
tape_low4_slot_start
        ; T0226: banner names of the 19 tape-only rooms + tape_names_tab
        ; (find_room_name's fallback, ui_room_names.asm)
        include "msg_data_tape_low4.asm"
tape_low4_slot_end
        ifndef STAGE_GEN
        ifgt tape_low4_slot_end-TAPE_LOW4_END
        error "TAPE_LOW_REGION4 content runs into start: at $0E00"
        endif
        endif
        endif

; T0224: BLOCKS C AND D, RAW (tape build only). The -run build packs them into
; the title stream's load-time holes and boot's unpack_c/unpack_d expand them.
; The tape build skips all of that: tools/stage_pack.sh writes the raw pass's
; block C / block D bytes to target/staged_{c,d}_raw_tape.bin and they are
; included HERE at their final addresses (RC_DEST, CODE_DEST), so they arrive as
; ordinary DECB segments >= $8000 that tape_stage1 copies up through its staged
; copy path -- the same way the tape-only room region arrives. No gather, no
; unpack, no title holes. Only in the packed pass (STAGE_LZ): the raw pass
; assembles them in place above.
        if TAPE_ROOMS
        if STAGE_LZ
        org RC_DEST
tape_c_raw_start
        if FLOPPY
        includebin "staged_c_raw_floppy.bin"
        else
        includebin "staged_c_raw_tape.bin"
        endif
tape_c_raw_end
        ifne tape_c_raw_end-IMAGE_END
        error "raw block C does not end exactly at IMAGE_END -- rerun tools/stage_pack.sh (stale staged_c_raw_tape.bin)"
        endif
        ifne tape_c_raw_end-tape_c_raw_start-TITLE_EXTRA_RAW
        error "staged_c_raw_tape.bin is not TITLE_EXTRA_RAW bytes"
        endif
        org CODE_DEST
tape_d_raw_start
        if FLOPPY
        includebin "staged_d_raw_floppy.bin"
        else
        includebin "staged_d_raw_tape.bin"
        endif
tape_d_raw_end
        ifgt tape_d_raw_end-tape_d_raw_start-CODE_BUDGET
        error "raw block D outgrew its CODE_BUDGET reservation"
        endif
        ifne tape_d_raw_end-tape_d_raw_start-TITLE_EXTRA2_RAW
        error "staged_d_raw_tape.bin is not TITLE_EXTRA2_RAW bytes"
        endif
        endif
        endif

; T0092 -- the packed title screen, org'd into the load-time holes below
; $8000 (framebuffer A spare, gap1, framebuffer B spare). Placed after the
; staged blocks so its orgs cannot disturb them; its labels are reached
; only through title_frags, never directly.
; T0231-fix: TAPE_ROOMS gets its OWN title_lz_tape.asm -- the holes are
; measured from the RAW pass, which now differs by TAPE_ROOMS (see the
; staged_syms.asm note above).
        if TAPE_ROOMS
        if FLOPPY
        include "title_lz_floppy.asm"
        else
        include "title_lz_tape.asm"
        endif
        else
        include "title_lz.asm"
        endif


; T0095 -- THE GUARD THAT SHOULD HAVE EXISTED BEFORE T0085 SHIPPED.
;
; Once packing existed the RAW image was allowed to outgrow the 12288
; bytes of staging window -- that is the point of T0085. But a raw build
; is still a loadable DECB file, and lwasm is perfectly happy to emit
; blocks that OVERLAP: block A simply runs past $5800 into the gap that
; holds the dizzy frame tail, the message VM and the font, and then on
; into block B. CLOADM applies blocks in FILE ORDER and the later one
; wins, so resident data is stomped and the game dies on boot.
;
; It assembled clean, it loaded, and it crashed -- the same failure the
; T0058 note in this file already warns about, reintroduced. memaudit.py
; catches it, but only if you run memaudit, and the plain
; `lwasm --decb -o target/room36.bin target/room36.asm` that earlier
; sessions used (and that old tasks.toml verify lines still carry) does
; not. So refuse to assemble instead of shipping a broken binary.
; stage_pack.sh's pass 1 is EXEMPT (-DSTAGE_GEN=1): it deliberately
; overflows, because its only job is to produce the bytes pass 2 packs
; and it is never loaded on a machine. Every other build is checked --
; including pass 2, where these labels bracket the PACKED blobs and so
; this is the check that actually matters.
        ifndef STAGE_GEN
STAGE_A_LEN  equ r8000_staged_end-r8000_staged_start
STAGE_B_LEN  equ r9800_staged_end-r9800_staged_start
STAGE_A_MAX  equ $5800-$4000
STAGE_B_MAX  equ $7800-$6000
; NOTE `ifgt <expr>`, not `if a > b`. lwasm's plain `if` is only
; "expression is non-zero" and does NOT implement `>` as a comparison:
; `if 1 > 2` is TRUE. The first version of this guard used that and
; fired on every build including the good ones, which is how a guard
; gets deleted instead of believed. ifgt is a real signed test against 0.
        ifgt (r8000_staged_end-r8000_staged_start)-STAGE_A_MAX
        error "staging block A overflows framebuffer A ($4000-$57FF) and would silently stomp the $5800 gap on load. Build with tools/stage_pack.sh -- an unpacked build cannot hold this much."
        endif
        ifgt (r9800_staged_end-r9800_staged_start)-STAGE_B_MAX
        error "staging block B overflows framebuffer B ($6000-$77FF). Build with tools/stage_pack.sh."
        endif
        endif

        end start
