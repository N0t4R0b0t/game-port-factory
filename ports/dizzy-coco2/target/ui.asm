; --------------------------------------------------------------------
; T0028: inventory/status UI. No dedicated status-bar routine was found
; in X-ALL.TXT (`lives`/`coins` are just bytes updated by game logic --
; NOTES.md T0011's win/death sections), so this is new, not a port: a
; fixed strip along the top of the screen showing lives, coins, and the
; carried-item icons, using the SAME building blocks everything else
; here uses -- prtmessage for the digits/letters, `blit` for the icons.
;
; T0078: grew from one 8px row to two (16px). Checked every built
; room's OWN topmost placement y first (extracted/rooms.json) -- the
; tightest, rooms 51/53, start at y=32, comfortably clear of both rows.
; Row 0 keeps the lives icon/count, coins and the carried-item icons;
; row 0 also gets a right-aligned "DIZZY" title (the icon area tops out
; around x=148px, "DIZZY" starts at x=216px -- checked, no overlap).
; Row 1 is the current room's name banner (ui_room_names.asm), matching
; the reference screenshot's two-row layout (research/D3-prior-art/
; info/dizzy3_game.png).
;
; T0079 draws the play-area FRAME below this (see draw_border at the
; bottom of this file). An earlier attempt put a solid bar there
; instead and the playtest verdict was exactly right: a rule under the
; banner is not a border round the play area.
;
; T0080 then moved the whole layout onto the original's own geometry --
; banner rows at y=8 and y=24, frame top band at y=40-47, play window
; y=48-183 (X-ALL.TXT windowtop/windowbottom), frame bottom band
; y=184-191. The room's art starts at y=48 BECAUSE 48 is where the
; original's window starts; before this the banner ended at y=23 and
; left a band of empty black above every room's ceiling.
;
; Drawn every redraw() pass in its own fixed region (above the window),
; cleared first for the same reason flames/actors are: `blit` only ORs
; ink on, and the damage-rect only covers Dizzy's own movement.
;
; SKIPPED ENTIRELY when nothing the strip shows has changed AND neither
; buffer was just invalidated -- a real playtest reported ongoing
; slowness even after the actor damage-rect culling and message-spam
; fixes, and this clear plus text redraw plus up to 3 icon blits running
; on literally EVERY pass, whether or not lives, coins, the room or the
; carried items had changed since the last one, was still real
; unconditional cost. Not per-buffer exact (the "last shown" state is
; one shared snapshot, not tracked separately per buffer the way
; bufA/B_last_x are) -- a genuine simplification, acceptable for a
; status strip that self-heals within a frame or two if it's ever
; wrong, unlike gameplay state.
; --------------------------------------------------------------------
draw_ui
        lda bufA_last_x
        cmpa #255
        beq ui_mustdraw
        lda bufB_last_x
        cmpa #255
        beq ui_mustdraw

        lda lives
        cmpa ui_last_lives
        bne ui_mustdraw
        lda coins
        cmpa ui_last_coins
        bne ui_mustdraw
        lda cur_room
        cmpa ui_last_room
        bne ui_mustdraw
        if DEBUG_XY
        ; NOTE: the banner is drawn before the move in a pass, so while
        ; WALKING the displayed x can trail the real one by a single 4px
        ; step. It converges the moment you stop, which is when a
        ; playtest reads it.
        ; T0191: the readout is useless if the banner only repaints when
        ; lives/coins/room change -- the digits updated in RAM and the
        ; screen did not ("the X and Y seem to be stuck"). Treat a move
        ; as a reason to redraw, same as the other watched values.
        lda dizzy_x
        cmpa ui_last_x
        bne ui_mustdraw
        lda dizzy_y
        cmpa ui_last_y
        bne ui_mustdraw
        endif
        rts                       ; nothing changed -- skip the redraw entirely

ui_mustdraw
        lda lives
        sta ui_last_lives
        lda coins
        sta ui_last_coins
        lda cur_room
        sta ui_last_room
        if DEBUG_XY
        lda dizzy_x
        sta ui_last_x
        lda dizzy_y
        sta ui_last_y
        endif

        ; T0080: the banner sits ABOVE the play window, so blit's window
        ; clip has to stand down for the whole of this routine -- text
        ; and icons alike -- and go back up before anything in the room
        ; is drawn again.
        clr win_top
        clr fb_flip               ; T0125: the banner is never upside down

        ; T0092: repaint the banner ART from BANNER_BUF every redraw.
        ;
        ; I removed this once, reasoning that the title screen had already
        ; painted rows 0-47 into both framebuffers and nothing ever clears
        ; them again. That reasoning was wrong and the eggs and border
        ; vanished -- reported from a playtest. The sweep still passed,
        ; because the sweep looks at physics and never at pixels; the
        ; frame rate still held 15.0 passes/sec. Nothing measured it
        ; because nothing measured the SCREEN.
        ;
        ; So: 1536 bytes a redraw, and it stays until something actually
        ; demonstrates which routine is clobbering the band. Do not
        ; "optimise" it out again on an argument alone -- capture the
        ; framebuffer and LOOK.
        ;
        ; T0237: that something is now a FINDING, not a hypothesis --
        ; harness/banner_writers.lua's write-taps caught it live:
        ; room36.asm's rd_cleardmg (redraw's damage-rect clear) sets a
        ; full-screen rect (dmg_y0=0) on a 255-sentinel "never drawn
        ; into" buffer, and only clamps it to win_top when fb_flip is
        ; set -- the unflipped path (every room used here) clears rows
        ; 0-47 unclamped. TAPE_ROOMS's own rd_cleardmg now clamps dmg_y0
        ; unconditionally (see its header), so the buffer-repaint below
        ; is dead weight in that build: nothing left clobbers the art
        ; between one redraw and the next except the two small TEXT
        ; slots this same routine draws into every pass anyway. The
        ; -run build is UNCHANGED (its rd_cleardmg keeps the original,
        ; unclamped-when-unflipped behaviour, so it still needs this).
        if TAPE_ROOMS
        ; Lives ('/' glyphs) and coins (2 digits) are the only things
        ; drawn into the banner every pass; clear just those two slots
        ; before drawing new text over them, the same way the room-name
        ; slot below already does for its own line.
        ;
        ; EXACT footprint, measured (not guessed) with /tmp/probe_banner.lua
        ; by forcing two different lives/coins values and diffing the
        ; resulting framebuffers: an 8x8 glyph is 8 ROWS tall, not one --
        ; a first attempt cleared only row 8 and a too-wide byte span,
        ; which ate one byte of the STATIC "DIZZY III" art immediately to
        ; the left (byte 6) with nothing left to ever repaint it (no more
        ; periodic BANNER_BUF restore in this build). Confirmed exact:
        ; lives occupies rows 8-15, bytes 7-8 only (2 reps max -- `lives`
        ; is never set above 2, see room36.asm's resetlives); coins
        ; occupies rows 8-15, bytes 23-24 only (2 digits, never >2 --
        ; coins never exceeds 30). Byte-for-byte, no margin: margin here
        ; means permanently erasing a neighbour, not "a little extra".
        ldy draw_base
        leay 8*32+7,y             ; rows 8-15, byte 7 -- lives slot
        lda #8                    ; 8 rows
ui_clrlivesrow
        clr ,y
        clr 1,y
        leay 32,y
        deca
        bne ui_clrlivesrow
        ldy draw_base
        leay 8*32+23,y            ; rows 8-15, byte 23 -- coins slot
        lda #8                    ; 8 rows
ui_clrcoinsrow
        clr ,y
        clr 1,y
        leay 32,y
        deca
        bne ui_clrcoinsrow
        else
        ldx #BANNER_BUF
        ldy draw_base
        lda #48                   ; rows
ui_bnrow
        pshs a
        ldb #16                   ; 32 bytes a row, 2 at a time
ui_bncol
        ldu ,x++
        stu ,y++
        decb
        bne ui_bncol
        puls a
        deca
        bne ui_bnrow
        endif

        ; Clear the title's "SPC OR FIRE TO START" out of the banner art's
        ; bottom slot, where the room name goes: its ink is exactly x=49..206
        ; of y=24..30 (measured from the art), so bytes 6..25 of rows 24..31
        ; take it all and leave the slot's frame alone. The top row is NOT
        ; cleared any more -- T0092: that was what erased the art's DIZZY III.
        ldy draw_base
        leay 24*32+6,y
        lda #8                    ; rows 24..31
ui_clrrow
        pshs a
        ldu #0
        ldb #10                   ; 20 bytes, 2 at a time
ui_clr1
        stu ,y++
        decb
        bne ui_clr1
        puls a
        leay 12,y                 ; back to byte 6 of the next row
        deca
        bne ui_clrrow

        ldx #ui_msg
        jsr prtmessage

        if DEBUG_XY
        ; T0191: -DDEBUG_XY=1 replaces the room name with Dizzy's live
        ; room/x/y. Four rounds of this session were spent guessing which
        ; platform a playtest meant and reproducing the wrong jump each
        ; time. Two numbers off the real screen ends that. Polling xroar's
        ; gdb stub from outside does NOT work at normal speed -- the stub
        ; only answers the halt interrupt with -no-ratelimit (see
        ; harness/bootreal.py) -- so the game has to show it.
        ldx #dbg_msg
        jsr prtmessage
        bra ui_noroomname
        endif
        jsr find_room_name
        cmpx #0
        beq ui_noroomname
        jsr prtmessage
ui_noroomname

        ; T0092: no carried-item icons in the banner. The original has none
        ; (its top row is lives, DIZZY III, coins), and the icons sat right
        ; on top of the lettering. Carried items are listed by name in
        ; show_inventory, which is where the original shows them.
        lda #WINDOW_TOP           ; T0080: window clip back on for the room
        sta win_top
        lda upsidedown            ; T0125: and the room's flip (draw_ui runs
        sta fb_flip               ; only from redraw, after its per-pass latch)
        rts

ui_last_lives fcb 255   ; deliberately non-matching at boot -- forces
ui_last_coins fcb 255   ; the first pass to draw regardless
ui_last_room  fcb 255   ; ditto -- cur_room starts at 36, never 255
        if DEBUG_XY
ui_last_x     fcb 255   ; T0191: so a MOVE also forces the banner redraw
ui_last_y     fcb 255
        endif

; Layout history (T0077 'Q' egg icon + digit, T0078 right-aligned DIZZY,
; T0091 hand-positioned DIZZY:III text) is in NOTES.md. All of it was
; replaced in T0092 by the original's own messages below, drawn into the
; banner art the title screen already provides.
; T0092: VERBATIM the original's two status messages (X-ALL.TXT
; `coinsmess` and `livesmess`, next to addtocoins/subfromlives):
;
;   coinsmess  mpen+6, mxy+46,8, <tens>,<units>, mend
;   livesmess  mpen+6, mxy+14,8, ":::", mxy+14,8, mrep,<lives>,"/",mendrep, mend
;
; so coins are two digits in the banner art's RIGHT slot (x=184) and lives
; are one '/' per spare life in the LEFT slot (x=56) -- glyph 47 in the
; original font IS the little egg. Both slots are black in the banner art,
; and the art is repainted before this draws, so the original's ":::"
; blank-out is not needed (blit only ORs ink on). A zero REPEAT count takes
; prtmessage's `noloop` skip, exactly as the original's does.
ui_msg
        fcb 128+46,8
ui_coin_digits
        fcc "00"
        fcb 128+14,8
        fcb 5                     ; REPEAT
ui_lives_rep
        fcb 0                     ;   lives times
        fcc "/"                   ;   an egg
        fcb 6                     ; END REPEAT
        fcb 0

        if DEBUG_XY
; T0191: "R<room> X<x> Y<y>", drawn where the room name goes. mxy is
; (128+x_in_4px_units, y_in_pixels) -- the same encoding ui_msg uses for
; the coin slot at x unit 46 = 184px.
dbg_msg
        ; SAME slot the room name uses (ui_room_names.asm: `fcb 128+12,24`
        ; -- x in 4px units, y in pixels). 128+1,32 put it on the banner's
        ; bottom frame: "drawing in the wrong place".
        fcb 128+12,24
        fcc "R"
dbg_room  fcc "000"
        fcc " X"
dbg_x     fcc "000"
        fcc " Y"
dbg_y     fcc "000"
        fcb 0

; dbg_dec3: A = value -> three ASCII digits at X
dbg_dec3
        pshs x
        ldb #100
        jsr ui_div
        adda #'0'
        sta ,x+
        lda ui_rem
        ldb #10
        jsr ui_div
        adda #'0'
        sta ,x+
        lda ui_rem
        adda #'0'
        sta ,x+
        puls x
        rts
        endif

; refresh_ui_text: patch lives and the coin digits into ui_msg. Coins
; never exceed 30, so two digits always suffice (the original's div10lp).
refresh_ui_text
        lda lives
        sta ui_lives_rep
        lda coins
        ldb #10
        jsr ui_div
        adda #'0'
        sta ui_coin_digits
        lda ui_rem
        adda #'0'
        sta ui_coin_digits+1
        if DEBUG_XY
        lda cur_room
        ldx #dbg_room
        jsr dbg_dec3
        lda dizzy_x
        ldx #dbg_x
        jsr dbg_dec3
        lda dizzy_y
        ldx #dbg_y
        jsr dbg_dec3
        endif
        rts

; ui_div: A = A / B (quotient returned in A, remainder in ui_rem). Coins
; never exceeds 30 so plain repeated subtraction is cheap enough here --
; no need for the 6809's full shift-and-subtract division routine.
ui_div
        pshs b                   ; save divisor
        clr ui_q
ud_lp
        cmpa ,s
        blo ud_done
        suba ,s
        inc ui_q
        bra ud_lp
ud_done
        sta ui_rem
        lda ui_q
        puls b
        rts

ui_q        fcb 0
ui_rem      fcb 0

; --------------------------------------------------------------------
; T0079: the play-area frame -- the border the reference screenshot
; (research/D3-prior-art/info/dizzy3_game.png) draws around the room,
; which the earlier solid divider bar was NOT: that was one line under
; the banner, this is a frame on all four sides.
;
; 8px thick, and it costs almost nothing in room art because the
; original clearly authored rooms to sit inside exactly this frame.
; Checked before building it, per room, against the generated placement
; lists (x, y and the sprite's OWN w/h, not just the anchor):
;
;   36, 52, 69   0 placements touch an 8px margin -- completely free
;   35, 53       2-3, all floor tiles whose bottom rows reach y>=184
;   54, 55, 68   2-5 decorative bits near an edge
;   51          12 (the worst: bushes at x=0-4, pillars at the bottom)
;
; The clincher is that DIZZY_MINX=8 and DIZZY_MAXX=224 (+24px sprite =
; 248) put Dizzy's OWN reachable span at exactly x=8..248 -- inset by
; exactly 8px each side. The frame therefore never overlaps the player,
; only the outer 8px of some scenery, which is what the original's own
; border does too.
;
; Drawn LAST in the redraw pass, after placements/actors/Dizzy/the
; banner, for the same reason T0062 moved Dizzy last: in a single
; serial pass, "drawn last" is what "always on top" means. That also
; means it does not need its own clear, and that a placement redrawn
; near an edge can never leave the frame broken.
;
; Pattern: a 4x4 checkerboard ($f0 four rows, then its COMB complement
; $0f for four) -- reads as a woven/checkered frame rather than a plain
; rule, closest thing to the original's checkered border that a 1bpp
; PMODE4 buffer can carry. Both bands and both side columns share it,
; so the corners line up.
; --------------------------------------------------------------------
; T0080: the frame now hugs the ORIGINAL's own play window. Its top
; band is the 8 rows immediately above WINDOW_TOP, its bottom band the
; 8 rows from WINDOW_BOTTOM -- which is exactly what X-ALL.TXT's
; `windowbottom defb 192-8` is measuring from.
BD_TOP_Y    equ WINDOW_TOP-8     ; frame's top band, 8 rows above the window
BD_BOT_Y    equ WINDOW_BOTTOM    ; frame's bottom band (8 rows to y=191)
BD_SIDE_N8  equ (192-BD_TOP_Y)/8 ; side columns, in whole bead tiles

draw_border
        ldx draw_base
        leax BD_TOP_Y*32,x
        jsr bd_band
        ldx draw_base
        leax BD_BOT_Y*32,x
        jsr bd_band

        ; side columns: byte 0 (x=0-7) and byte 31 (x=248-255) of every
        ; row from the top band down, walked 8 rows at a time so the
        ; bead lines up with the bands and the corners meet cleanly.
        ldx draw_base
        leax BD_TOP_Y*32,x
        lda #BD_SIDE_N8
        sta bd_n
bd_sidegrp
        ldy #bd_pat
bd_siderow
        ldb ,y+
        stb ,x
        stb 31,x
        leax 32,x
        cmpy #bd_pat_end
        bne bd_siderow
        dec bd_n
        bne bd_sidegrp
        rts

; bd_band: X -> first byte of an 8-row band; fills 32 bytes/row with the
; bead tile. The 16 STDs are unrolled deliberately -- a counted inner
; loop measured a bit over twice the cycles for the same 32 bytes, and
; this runs every pass.
bd_band
        ldy #bd_pat
bd_bandrow
        ldb ,y+
        tfr b,a                   ; A:B both = this row, so STD paints 2
        std ,x++
        std ,x++
        std ,x++
        std ,x++
        std ,x++
        std ,x++
        std ,x++
        std ,x++
        std ,x++
        std ,x++
        std ,x++
        std ,x++
        std ,x++
        std ,x++
        std ,x++
        std ,x++
        cmpy #bd_pat_end
        bne bd_bandrow
        rts

; T0087: the frame tile -- an egg-shaped bead, 8x8, repeated. Replaces
; the 4x4 checkerboard T0079 started with, which the playtest called
; "not very on theme": narrow at the top, wide at the bottom, so a run
; of them reads as a string of beads shaped like Dizzy himself rather
; than as a chessboard. One tile serves the bands and the side columns
; both, which is what keeps the corners meeting.
bd_pat  fcb $18,$3c,$7e,$7e,$ff,$ff,$7e,$3c
bd_pat_end

bd_n        fcb 0
