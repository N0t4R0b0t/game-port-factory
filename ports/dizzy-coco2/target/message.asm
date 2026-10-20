; --------------------------------------------------------------------
; T0025: the message system -- a FULL port of the original's `prtmessage`
; control-code interpreter (X-ALL.TXT ~4823), not a plain string printer.
; Messages are byte streams mixing literal characters with opcodes:
;
;   0        END -- return
;   3 t      set plot type (bit0 = draw chars, bit1 = draw attributes)
;   4 addr   GOSUB: run the message at addr, then carry on here
;   5 n      REPEAT n times from here
;   6        END REPEAT
;   9 w h    DRAW BOX w x h (in character cells)
;   10       NOP, but advances the cursor like a character would
;   16+p     set pen p (0-7); stored as p+64 exactly as the original does
;   32-90    literal character -- drawn as glyph frame == ASCII code
;   91-127   T0225 DTE code -- no glyph exists above 90 (font_data.asm's
;            FONT_LAST=90), so this range drew nothing anyway; repurposed
;            as a 2-byte-pair expansion, see pm_dte/dte_table.asm.
;   128+x, y set cursor to (x, y)
;
; T0225: nine more byte values are ALSO free DTE codes even though they're
; below 16 -- 1,2,7,8,11,12,13,14,15, i.e. every value <16 that isn't one
; of the seven named opcodes above. The VM used to just skip them (1-byte
; NOP); now they fall into the same pm_dte handler as the 91-127 range.
; Together that's 46 codes (see tools/dte/src/lib.rs, the single source
; of truth for the range split), used to byte-pair-encode every fcc
; string in the resident text corpus (measured saving in NOTES.md T0225).
;
; Pairing only ever happens INSIDE encoded text runs -- the tool guards at
; build time that no literal text byte lands outside 32..=90, so a DTE
; code's pair members are always themselves text bytes or further DTE
; codes, never an XY/pen/opcode byte. pm_emit (the recursive expander)
; relies on that guarantee and does not re-check it at runtime.
; Coordinates match the room system: msg_x is in 4-PIXEL UNITS (so a
; character, 8px wide, advances it by 2), msg_y is in pixels. The
; original's `add a,32` screen-origin offset is folded out here, exactly
; as the room placement transform already does.
;
; The attribute half of `plottype` (bit 1) is inert on CoCo2 -- PMODE4
; has no attribute plane at all -- so pen is tracked faithfully but only
; consulted for box drawing. Kept rather than dropped so message streams
; stay byte-compatible with the original's data.
;
; Branches back to pm_loop are LONG (lbra/lbeq) throughout: the
; interpreter body is well over 127 bytes end to end.
; --------------------------------------------------------------------
prtmessage                       ; X -> message stream
pm_loop
        lda ,x+
        bmi pm_xy                ; bit 7 set -> 128+x, y
        cmpa #91                 ; T0225: 91-127 -> DTE code (no glyph
        lbhs pm_dte                ; exists there, so this was dead space) --
                                  ; LONG branch, pm_dte lives past pm_drawbox
        cmpa #32
        bhs pm_char
        cmpa #16
        bhs pm_pen
        tsta
        beq pm_done              ; 0 = END
        cmpa #3
        beq pm_plot
        cmpa #4
        beq pm_gosub
        cmpa #5
        beq pm_repeat
        cmpa #6
        beq pm_endrep
        cmpa #9
        beq pm_drawbox
        cmpa #10
        beq pm_nop
        ; T0225: every value that reaches here is one of the nine LOW_SET
        ; DTE codes (1,2,7,8,11,12,13,14,15) -- guaranteed, since the seven
        ; real low opcodes were all just matched above. Not "unknown" any
        ; more; the old skip-it fallback is now pm_dte (LONG branch, same
        ; reason as the lbhs above).
        lbra pm_dte
pm_done
        rts

pm_xy
        suba #128
        sta msg_x
        lda ,x+
        sta msg_y
        lbra pm_loop

pm_pen
        suba #16
        adda #64                 ; original stores pen as p+64
        sta msg_pen
        lbra pm_loop

pm_plot
        lda ,x+
        sta msg_plot
        lbra pm_loop

pm_char
        ldb msg_plot
        bitb #1                  ; plot-characters disabled? just advance
        beq pm_advance
        pshs x
        jsr putglyph
        puls x
pm_advance
        lda msg_x
        adda #2                  ; one character = 8px = 2 units
        sta msg_x
        lbra pm_loop

pm_nop
        lda msg_x
        adda #2
        sta msg_x
        lbra pm_loop


pm_gosub
        ldu ,x++                 ; U = subroutine address, X now past it
        pshs x
        tfr u,x
        jsr prtmessage           ; real recursion -- END returns here
        puls x
        lbra pm_loop

pm_repeat
        lda ,x+                  ; repeat count
        beq pm_rep_zero
        pshs a                   ; [count]
        pshs x                   ; [count][loop start]
        lbra pm_loop
pm_rep_zero
        leax 2,x                 ; matches the original's `noloop` skip
        lbra pm_loop

pm_endrep
        puls u                   ; U = loop start (pushed last)
        puls a                   ; A = remaining count
        deca
        lbeq pm_loop             ; done: continue past the endrepeat
        pshs a
        pshs u
        tfr u,x                  ; go round again
        lbra pm_loop

pm_drawbox
        lda ,x+
        sta box_w
        lda ,x+
        sta box_h
        pshs x
        jsr draw_box
        puls x
        lbra pm_loop

; --------------------------------------------------------------------
; T0225: DTE (byte-pair) text decompression. pm_dte is the entry point
; from pm_loop -- A holds the raw byte just read from the message stream
; (either 91-127, or one of the nine LOW_SET codes: 1,2,7,8,11-15). It
; expands to a table index 0..DTE_CODE_COUNT-1 and hands off to pm_emit,
; which recurses through nested pairs down to literal characters.
;
; X (the message stream pointer) is preserved across the whole expansion
; with one pshs/puls here -- pm_emit and everything it calls are free to
; clobber X for their own table lookups (font_table, dte_table) since
; none of them ever need the stream pointer.
; --------------------------------------------------------------------
pm_dte
        pshs x
        jsr pm_emit
        puls x
        lbra pm_loop

; pm_emit: emit character/DTE-code A. Recursive (bsr), does not touch the
; message stream -- only ever called with a text byte (32-90) or a DTE
; code (1,2,7,8,11-15,91-127), per the encoder's own guarantee that pairs
; never straddle an XY/pen/opcode byte.
pm_emit
        cmpa #91
        bhs pme_hi
        cmpa #32
        bhs pme_char
        ; else: one of the nine LOW_SET codes -- dte_low_index maps the
        ; raw byte value straight to its dte_table index. X is free to
        ; clobber (see pme_lookup's own note).
        ldx #dte_low_index
        lda a,x
        bra pme_lookup
pme_hi
        suba #91                 ; HI codes start right after LOW_SET's
        adda #9                  ; nine dte_table entries (see lib.rs)
        bra pme_lookup
pme_char
        ldb msg_plot
        bitb #1
        beq pme_adv
        pshs x
        jsr putglyph
        puls x
pme_adv
        lda msg_x
        adda #2
        sta msg_x
        rts
pme_lookup
        ; A = dte_table index (0..DTE_CODE_COUNT-1). X is free to clobber
        ; here -- nothing after this point needs it (the real message
        ; stream pointer is protected once, by pm_dte's own pshs/puls x).
        tfr a,b
        aslb
        ldx #dte_table
        leax b,x
        ldd ,x                   ; A = pair[0], B = pair[1]
        pshs b                   ; stash pair[1] -- pm_emit below clobbers B
        bsr pm_emit               ; emit pair[0] (recurses if it's a DTE code)
        puls a                   ; A = pair[1]
        bsr pm_emit               ; emit pair[1]
        rts

; T0225: fixed position of each LOW_SET raw byte value within dte_table
; (indices 0-8; HI codes 91-127 fill indices 9+). Indexed directly by the
; raw byte value via 6809 accumulator-offset addressing (`lda a,x`), same
; style putglyph already uses for font_table. Only the nine LOW_SET
; positions are ever read (pm_loop only reaches pm_emit's "else" branch
; for one of those nine values); the rest of the table is unreachable
; padding.
dte_low_index
        fcb 0,0,1,0,0,0,0,2,3,0,0,4,5,6,7,8
                            ; raw byte: 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15
                            ; dte_table index, only read for bytes
                            ; 1,2,7,8,11,12,13,14,15 (LOW_SET, in that
                            ; fixed order -> indices 0-8)

        include "dte_table.asm"

; --------------------------------------------------------------------
; putglyph: draw the character in A at the message cursor. The glyph
; frame index IS the ASCII code (verified: frames 65-90 render as
; exactly A-Z), so this is a table lookup plus a call into the SAME
; `blit` the scenery uses -- no separate text blitter, and sub-byte x
; alignment comes free because msg_x*4 is always a multiple of 4.
;
; Characters outside the glyph block are skipped rather than drawing
; whatever sprite lives at that frame index: frames 32-37 are 6x28
; scenery objects, so rendering one for a stray space would splatter
; the screen.
; --------------------------------------------------------------------
putglyph
        cmpa #FONT_FIRST
        blo pg_skip
        cmpa #FONT_LAST
        bhi pg_skip
        suba #FONT_FIRST
        asla                     ; fdb table: 2 bytes per entry
        ldx #font_table
        leax a,x
        ldd ,x
        std blit_ptr
        lda msg_x
        lsla
        lsla                     ; 4-pixel units -> pixels
        sta blit_x
        lda msg_y
        sta blit_y
        jsr blit
pg_skip
        rts

; --------------------------------------------------------------------
; draw_box: the window frame for opcode 9, built from the same
; box-drawing glyphs the original uses (42 top-left, 40 horizontal,
; 43 top-right, 44 vertical). Structurally faithful -- same glyphs in
; the same corner/edge roles -- but the interior is cleared to black
; rather than filled with a paper colour, because PMODE4 has no paper:
; "clear" and "black" are the same operation here.
;
; box_w/box_h are in character cells. Draws at the current cursor and
; restores it, so a following XY opcode positions text inside normally.
; --------------------------------------------------------------------
draw_box
        lda msg_x
        sta box_sx
        lda msg_y
        sta box_sy

        ; --- interior clear ---
        ; Zero the box area first so room art doesn't show through the
        ; window: `blit` composites with OR and can only ADD ink, so
        ; without this the frame and text would land on top of the
        ; dungeon wall instead of on a clean panel.
        ; box_sx is in 4px units, so >>1 converts it to byte columns.
        lda box_sx
        lsra
        sta box_c0
        lda box_w
        adda #4
        sta box_c                ; width in cells == width in bytes
                                  ; X-ALL.TXT's box is W+4 glyphs wide:
                                  ; corner, edge, W*segment, edge, corner
        lda box_h
        adda #3
        lsla
        lsla
        lsla                     ; cells -> pixel rows
        sta box_r
        lda box_sy
        sta box_cy
db_clrrow
        lda #FBWIDTH
        ldb box_cy
        mul
        addd draw_base
        tfr d,x
        ldb box_c0
        abx
        ldb box_c
        clra
db_clrcell
        sta ,x+
        decb
        bne db_clrcell
        inc box_cy
        dec box_r
        bne db_clrrow

        ; --- top edge ---
        ; X-ALL.TXT horizontalbars puts it at messy+8, not messy. Being a
        ; glyph row high is what pushed the text off-centre vertically:
        ; the interior must run messy+16 .. messy+h*8+15, which is exactly
        ; what the original's text coordinates are centred in.
        lda box_sx
        sta msg_x
        lda box_sy
        adda #8
        sta msg_y
        lda #42
        jsr db_put
        lda #46
        jsr db_put
        lda box_w
        sta box_c
db_toplp
        lda #40
        jsr db_put
        dec box_c
        bne db_toplp
        lda #46
        jsr db_put
        lda #43
        jsr db_put

        ; --- bottom edge ---
        lda box_sx
        sta msg_x
        lda box_h
        lsla
        lsla
        lsla                     ; cells -> pixels
        adda box_sy
        adda #16                 ; messy + 8 + h*8 + 8
        sta msg_y
        lda #42
        jsr db_put
        lda #46
        jsr db_put
        lda box_w
        sta box_c
db_botlp
        lda #40
        jsr db_put
        dec box_c
        bne db_botlp
        lda #46
        jsr db_put
        lda #43
        jsr db_put

        ; --- side edges ---
        ; X-ALL.TXT verticalbar: ONE glyph 44 at messy, then h glyph-41
        ; pieces starting at messy+16. The 8px gap between is the top
        ; border band, which spans every column including these two.
        lda box_sy
        sta box_cy
        lda #44
        jsr db_sides
        lda box_sy
        adda #16
        sta box_cy
        lda box_h
        sta box_r
db_sidelp
        lda #41
        jsr db_sides
        lda box_cy
        adda #8
        sta box_cy
        dec box_r
        bne db_sidelp

        lda box_sx               ; restore the cursor
        sta msg_x
        lda box_sy
        sta msg_y
        rts

; draw glyph A at BOTH side columns (glyph column 1 and W+2) on row box_cy
db_sides
        sta box_gl
        lda box_sx
        adda #2                  ; glyph column 1 (verticalbars' `inc e/inc e`)
        sta msg_x
        lda box_cy
        sta msg_y
        lda box_gl
        jsr db_put
        lda box_w
        adda #2
        asla                     ; (w+2) cells right, in 4px units
        adda box_sx
        sta msg_x
        lda box_cy
        sta msg_y
        lda box_gl
        jsr db_put
        rts

; draw glyph A at the cursor, then step one cell right
db_put
        pshs x
        jsr putglyph
        puls x
        lda msg_x
        adda #2
        sta msg_x
        rts

; --- message-system state -------------------------------------------
msg_x         fcb 0      ; cursor x in 4-pixel units
msg_y         fcb 0      ; cursor y in pixels
msg_pen       fcb 64     ; pen, stored as colour+64 as the original does
msg_plot      fcb 1      ; bit0 = draw chars, bit1 = attrs (inert here)
box_w         fcb 0
box_h         fcb 0
box_sx        fcb 0
box_sy        fcb 0
box_c         fcb 0
box_c0        fcb 0
box_r         fcb 0
box_cy        fcb 0
box_gl        fcb 0      ; glyph the side-bar helper is drawing
