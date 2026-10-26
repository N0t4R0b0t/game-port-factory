; ---------------------------------------------------------------------------------------------
; T0261 (D4) -- FLOPPY build only: placements that lie PARTLY off the room's left edge.
;
; The original draws the visible columns of a sprite placed at a negative x (X-ALL: the window
; clip in `frame`).  This port's placement record has one unsigned x byte and blit has no left
; clip, so roompack drops those placements, in every build.  In the FLOPPY build they are put back
; at RUN time instead of as stored cropped bitmaps (~1000 B that no build has room for):
;
;   * tools/roompack (RP_CLIP_DATA) writes target/floppy_clip_tab.asm (clip_tab: room, sprite header,
;     cut in pixels, y -- 5 bytes per placement, room 0 ends it; CLIP_BUF_LEN = the largest per-room total)
;     and target/floppy_clip_sprites.asm (the WHOLE sprites, clipspr_<frame>).
;   * load_room -> rd_sortplaces -> clip_room_add: for each entry of the room it crops the sprite into
;     CLIPBUF (a fresh header + the visible columns: a whole-byte skip, plus a 4-pixel left shift when the
;     cut is not a multiple of 8) and inserts the placement (x = 0) into the y-sorted draw list, so
;     redraw_placements_dmg / rd_placelp / blit draw it like any other placement (blit is unchanged).
;   * The collision mask is NOT touched: derive_room_cmask runs before this and the masks already
;     contain these placements (tools/derive_cmask.py "full", dc_patch for rooms 51/84/60).
;
; Not mirrored ones: none exists (roompack asserts it).  CLIPBUF is bss at the end of the tape-only region.
; ---------------------------------------------------------------------------------------------
clip_room_add
        ldx #clip_tab
        stx cl_tp
        ldx #CLIPBUF
        stx cl_free
cl_next
        ldx cl_tp
        lda ,x+                  ; room (0 = end of table)
        beq cl_done
        cmpa cur_room
        bne cl_skip
        ldu ,x++                 ; U = the whole sprite's header
        ldd ,x++                 ; A = cut (pixels), B = y
        stx cl_tp
        sta cl_cut
        stb sp_new+3
        ldx cl_free
        stx sp_new               ; the placement points at the cropped copy
        clr sp_new+2             ; x = 0, no mirror / decorative flag
        jsr cl_build             ; X = next free byte of CLIPBUF
        stx cl_free
        jsr cl_insert
        bra cl_next
cl_skip
        leax 4,x                 ; sprite ptr (2), cut, y
        stx cl_tp
        bra cl_next
cl_done
        rts

; cl_build: U = whole sprite header (w, h, bpr, bitmap), X = destination, cl_cut = pixels to cut
; (a multiple of 4, < w).  Writes the cropped sprite (header + bitmap) at X and leaves X after it.
cl_build
        ldb ,u                   ; w
        subb cl_cut
        stb ,x+                  ; visible width
        addb #7
        lsrb
        lsrb
        lsrb
        stb cl_obpr              ; bytes per row of the copy
        lda 1,u
        sta ,x+                  ; h
        sta cl_rows
        stb ,x+                  ; bpr
        ldb 2,u
        stb cl_sbpr              ; bytes per row of the source
        ldb cl_cut
        lsrb
        lsrb
        lsrb
        stb cl_sb                ; whole source bytes skipped
        lda cl_sbpr
        suba cl_sb
        sta cl_avail             ; source bytes left in a row after the skip
        lda cl_cut
        anda #4
        sta cl_nib               ; 4 = the copy is the source shifted left by 4 pixels
        leau 3,u                 ; -> bitmap
cl_row
        pshs u                   ; start of this source row
        ldb cl_sb
        leau b,u
        clr cl_j
cl_byte
        lda ,u+
        tst cl_nib
        beq cl_store
        asla                     ; s0 << 4 | s1 >> 4  (s1 only if it is in this row)
        asla
        asla
        asla
        ldb cl_j
        incb
        cmpb cl_avail
        bhs cl_store
        ldb ,u
        lsrb
        lsrb
        lsrb
        lsrb
        pshs b
        ora ,s+
cl_store
        sta ,x+
        inc cl_j
        ldb cl_j
        cmpb cl_obpr
        blo cl_byte
        puls u
        ldb cl_sbpr
        leau b,u                 ; next source row
        dec cl_rows
        bne cl_row
        rts

; cl_insert: stable insertion of sp_new into ROOM_PLACE_SORTED (rd_sortplaces' own step).
cl_insert
        lda sp_count
        deca
        sta sp_j
cl_findlp
        lda sp_j
        bmi cl_found
        jsr sp_addr
        lda 3,x
        cmpa sp_new+3
        bls cl_found
        ldd ,x
        std 4,x
        ldd 2,x
        std 6,x
        dec sp_j
        bra cl_findlp
cl_found
        lda sp_j
        inca
        jsr sp_addr
        ldd sp_new
        std ,x
        ldd sp_new+2
        std 2,x
        inc sp_count
        rts

cl_tp     fdb 0
cl_free   fdb 0
cl_cut    fcb 0
cl_obpr   fcb 0
cl_rows   fcb 0
cl_sbpr   fcb 0
cl_sb     fcb 0
cl_avail  fcb 0
cl_nib    fcb 0
cl_j      fcb 0

        include "floppy_clip_tab.asm"
        include "floppy_clip_sprites.asm"
