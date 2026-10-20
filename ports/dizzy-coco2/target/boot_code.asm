; BOOT-ONLY code and its scratch, relocated out of the $0E00-$4000
; region (T0104).
;
; T0103's actor collision pushed that region 195 bytes past $4000 and
; into framebuffer A's staging block -- caught by memaudit's cross-block
; overlap check, which is exactly the silent-corruption class it exists
; for, and which I missed once by grepping stage_pack's output for
; "error" instead of reading the audit.
;
; Everything here is reached only by absolute jsr/ldx, so where it lives
; is arbitrary; this follows the same move ui.asm and gap_messages.asm
; already made into the $0100 region.
; seed_inventory: put START_ITEM1..3 into Dizzy's hands at boot.
;
; TEST AID, and a no-op unless -DSTART_ITEMn is passed. `inv` holds an
; actor INDEX+1, not a frame, so seeding has to find the actor carrying
; that frame, take it out of the world (room=255, exactly what tp_take
; does) and push its index. Doing it any other way leaves the item both
; in your hands and lying in the room.
;
; Items are inserted in reverse so START_ITEM1 ends up newest/first,
; matching the order they would appear if picked up left to right.
        if SEED_INV
seed_inventory
        ldx #si_items+2
        lda #3
        sta si_n
si_loop
        lda ,x                   ; frame wanted, 0 = slot unused
        beq si_next
        pshs x
        jsr si_find              ; -> B = actor index, A = found flag
        tsta
        beq si_nofind
        incb                     ; inv stores index+1
        stb tp_slot
        jsr inv_insert
si_nofind
        puls x
si_next
        leax -1,x
        dec si_n
        bne si_loop
        rts

; si_find: A = frame to look for. Returns A=1/B=index if a live actor in
; the table carries it, A=0 otherwise.
si_find
        pshs a
        ldy #actor_ram
        clrb
si_fl
        cmpb #ACTOR_COUNT
        beq si_fnone
        lda 4,y                  ; this actor's frame
        cmpa ,s
        bne si_fnext
        lda #255
        sta ,y                   ; out of the world, as a pickup would
        puls a
        lda #1
        rts
si_fnext
        incb
        leay ACTOR_STRIDE,y
        bra si_fl
si_fnone
        puls a
        clra
        rts

si_items fcb START_ITEM1,START_ITEM2,START_ITEM3
si_n     fcb 0
        endif

; --- T0126: LZ unpacker, ZX0-style bit stream ----------------------------
;
; U = packed stream, Y = destination. Used at boot for both staged blocks,
; the title and its music, and by load_room for every room's collision
; mask. tools/roompack/src/lz.rs is the other half and the one place the
; grammar is spelled out in full:
;
;   bits MSB-first from "bit bytes", raw bytes interleaved in the stream
;   GAMMA = interlaced Elias gamma: (0, bit) per bit below the top, then 1
;   after a match:   0 = literals  n=GAMMA, then n raw bytes    1 = new match
;   after literals:  0 = repeat    n=GAMMA, from the last offset 1 = new match
;   new match:       m=GAMMA (256 = end), offset=((m-1)<<8 | raw)+1, n=GAMMA+1
;
; Replaced T0085's byte-aligned LZSS, which packed this game's room data to
; only 76-81% (this: ~62-65%) -- ~2.7KB of load-time space for about the
; same decoder size. Still no decode RAM: the window IS the destination
; buffer, and overlapping copies run forwards a byte at a time (offset 1 is
; how a run is encoded).
lz_unpack
        lda #$80
        sta lz_bits               ; bit buffer empty: just the sentinel
        clr lz_state              ; the stream starts "after a match"
        ldd #$ffff                ; ...with last offset 1 (-1 here), exactly as
        std lz_dist               ; the encoder starts: it CAN emit a repeat of
                                  ; offset 1 before any new match sets one, and
                                  ; leaving this unset reused the previous call's
                                  ; offset (lzverify: 3 bytes wrong; every room
                                  ; mask garbled)
lz_token
        bsr lz_getbit
        bcs lz_new                ; 1: new-offset match, from either state
        bsr lz_gamma              ; 0: a count; what it counts is the state's
        tst lz_state
        bne lz_rep                ; after literals: repeat the last offset
lz_litlp                          ; after a match: a literal run
        lda ,u+
        sta ,y+
        ldd lz_rem
        subd #1
        std lz_rem
        bne lz_litlp
        inc lz_state              ; now "after literals"
        bra lz_token
lz_new
        bsr lz_gamma              ; offset high part + 1 (256 = end)
        ldd lz_rem
        cmpd #256
        beq lz_done
        decb                      ; B = high byte of offset-1 (A is 0)
        lda ,u+                   ; low byte of offset-1
        exg a,b                   ; D = offset-1
        coma
        comb                      ; D = ~(offset-1) = -offset
        std lz_dist
        bsr lz_gamma
        ldd lz_rem
        addd #1                   ; length = GAMMA+1
        std lz_rem
lz_rep                            ; (a repeat reuses lz_dist as it stands)
        clr lz_state              ; a match: now "after a match"
        ldd lz_dist
        leax d,y                  ; X = Y - offset
lz_cplp
        lda ,x+
        sta ,y+
        ldd lz_rem
        subd #1
        std lz_rem
        bne lz_cplp
        bra lz_token
lz_done
        rts

; lz_getbit: next bit into C. When only the sentinel is left, refill from
; the stream: the new byte's top bit comes out, a fresh sentinel goes in.
lz_getbit
        lsl lz_bits
        bne lz_gbx
        lda ,u+
        orcc #1                   ; C=1: the new sentinel
        rola
        sta lz_bits
lz_gbx  rts

; lz_gamma: interlaced Elias gamma -> lz_rem
lz_gamma
        ldd #1
        std lz_rem
lz_gmlp
        bsr lz_getbit
        bcs lz_gmx                ; 1: stop
        bsr lz_getbit
        rol lz_rem+1
        rol lz_rem
        bra lz_gmlp
lz_gmx  rts

; T0231-fix: TAPE_ROOMS gets its OWN title_frags_tape.asm -- fragment
; addresses are load-time HOLES, which move with resident code size (see
; room36.asm's staged_syms.asm note for the full reasoning).
; T0224: in the tape build that file carries ONLY the TITLE_* length equates
; now (blocks C/D are raw tape segments, there are no fragments and no
; title_frags gather table).
        if TAPE_ROOMS
        if FLOPPY
        include "title_frags_floppy.asm"  ; T0241: its own artifact (never the tape build's)
        else
        include "title_frags_tape.asm"    ; T0224: equates only
        endif
        else
        include "title_frags.asm"    ; T0092 gather table (generated)
        endif
ti_len   fdb 0
ti_coln  fcb 0
ti_rown  fcb 0

lz_rem   fdb 0
lz_dist  fdb 0
lz_bits  fcb 0
lz_state fcb 0

; show_title: the T0092 boot title sequence, lifted out of start:.
; Straight-line boot code, so moving it costs one jsr/rts and buys
; back ~180 bytes of the $0E00-$4000 region.
show_title
        ;
        ; Runs here, after the rooms are unpacked, because it reuses
        ; lz_unpack and needs SAM all-RAM for its scratch buffers. The
        ; packed stream arrives SPLIT across the load-time holes below
        ; $8000 -- it is 3788 bytes and the framebuffer staging windows
        ; only have 3495 spare between them. The fragments are not decoded
        ; in place: gather them into one buffer first and the ordinary
        ; unpacker handles the rest, so there is no second decoder and no
        ; change to the stream format. tools/mktitle.rs is the other half.
        ; T0219 (TAPE_ROOMS only): the title+music part of the stream is
        ; NOT in the holes any more -- it is already resident at
        ; TITLE_RESIDENT_LZ (kept for the game-over replay, T0231/T0237),
        ; byte-identical to the first TITLE_LZ_LEN+TITLE_MUSIC_LEN bytes
        ; of the gathered stream. Copy that FIRST (U ends one past it),
        ; then gather only block C + block D from the holes
        ; (mktitle --dedup-resident leaves them out of title_frags).
        ; Same final layout at TITLE_LZ_BUF as before, so unpack_c/unpack_d
        ; offsets are unchanged. Saves ~3266 bytes of load-time holes.
        ; T0224 (TAPE_ROOMS): blocks C and D no longer ride the title stream.
        ; They are raw tape segments at RC_DEST/CODE_DEST, so there is nothing
        ; to gather after the resident prefix and no unpack_c/unpack_d.
        if TAPE_ROOMS
        lbsr title_copy_resident
        else
        ldx #title_frags
        ldu #TITLE_LZ_BUF
ti_gather
        ldy ,x++                ; fragment source
        ldd ,x++                ; fragment length, 0 ends the list
        beq ti_gathered
        std ti_len
ti_gcopy
        lda ,y+
        sta ,u+
        ldd ti_len
        subd #1
        std ti_len
        bne ti_gcopy
        bra ti_gather
ti_gathered
        endif
; T0146: this used to be a second entry point (show_title_again) that game
; over jumped back to, which is why TITLE_LZ_BUF had to stay resident for
; the whole game. Game over now shows a text screen instead (update_death's
; msg_gameover) and never re-runs any of this, so show_title is genuinely
; boot-only: the gathered stream at TITLE_LZ_BUF ($4000, framebuffer A) can
; be drained -- title image, mixer blob, AND block C's room data (rooms 39,
; 23; T0125's unpack_c, formerly re-run from new_game on every game because
; the stream used to be permanent anyway) -- and then overwritten by the
; transpose below, all in this one boot-time pass.
        ldu #TITLE_LZ_BUF
        ldy #$6000                 ; T0147: scratch through idle framebuffer B
        jsr lz_unpack

        ; T0146: the mixer blob and block C must come out of the gathered
        ; stream HERE, while it's still intact at TITLE_LZ_BUF -- the
        ; transpose below overwrites it with the finished title image.
        if TITLE_MIX3
        ldu #TITLE_LZ_BUF+TITLE_LZ_LEN
        ldy #MIX3_BUF
        jsr lz_unpack
        endif
        if TAPE_ROOMS
        else
        jsr unpack_c               ; T0125/T0146: rooms 39+23, once, not per-game
        jsr unpack_d               ; T0148: update_dragon+dragon_flames CODE, once
        endif

; T0231: ti_transpose -- entry point that picks up right after the title
; image + music are unpacked into TITLE_LZ_BUF/MIX3_BUF, skipping the
; gather and block C/D unpack above. Used by show_title_resident (below,
; TAPE_ROOMS only), the tape build's game-over title replay: it must NOT
; re-run unpack_c/unpack_d (RC_DEST/CODE_DEST already hold live resident
; data/code by the time a game-over can happen -- see their own headers).
ti_transpose
        ; Undo the column-major ordering straight into framebuffer A:
        ;   fb[row*32 + col] = raw[col*192 + row]
        ; Column-major is worth 557 packed bytes on this dithered image
        ; (3788 vs 4345) and costs only this loop -- see mktitle.rs for
        ; the orderings that were measured and lost.
        ldu #$6000
        ldx #$4000
        lda #32
        sta ti_coln
ti_col
        tfr x,y
        lda #192
        sta ti_rown
ti_row
        ldb ,u+
        stb ,y
        leay 32,y
        dec ti_rown
        bne ti_row
        leax 1,x
        dec ti_coln
        bne ti_col

        ; Both framebuffers, so the title is visible whichever one the
        ; SAM is pointing at -- flip_buffer's state is not established
        ; this early and guessing it wrong shows a screen of garbage.
        ldx #$4000
        ldy #$6000
        ldd #6144
        std ti_len
ti_dup
        lda ,x+
        sta ,y+
        ldd ti_len
        subd #1
        std ti_len
        bne ti_dup

        ; Keep the top 48 rows: they ARE the in-game banner art (the
        ; DIZZY III lettering with an egg either side), so the banner
        ; costs nothing beyond this copy.
        ;
        ; T0237: TAPE_ROOMS no longer needs this resident copy at all --
        ; draw_ui stopped repainting FROM it (ui.asm's own T0237 note;
        ; rd_cleardmg's real clobber is clamped instead now), so nothing
        ; ever reads BANNER_BUF in that build any more. Skipping the
        ; copy frees BANNER_BYTES in the tape-only region (room36.asm's
        ; BANNER_BUF/CODE_DEST, same round). The -run build (else) is
        ; UNCHANGED.
        if TAPE_ROOMS
        else
        ldx #$4000
        ldy #BANNER_BUF
        ldd #BANNER_BYTES
        std ti_len
ti_bcopy
        lda ,x+
        sta ,y+
        ldd ti_len
        subd #1
        std ti_len
        bne ti_bcopy
        endif

        ; Hold on the title until SPACE, then wait for the release so the
        ; same press does not fall through and dismiss the first message.
        ; T0089: the real captured title tune (X-ALL.TXT `xor a / call
        ; starttune` right before this same wait loop) plays here,
        ; looping the table and checking for SPACE between each note so
        ; a press is never more than one note late.
        if TITLE_MIX3
        ; 3-voice title (target/title_mix3.asm): unpacked into MIX3_BUF
        ; already, above (T0146 -- moved out of here so it could still run
        ; before the transpose overwrites its source). It runs with its
        ; variables on MIX3_DP, and returns when SPACE goes down. DP back
        ; to 0 afterwards: the game assumes it.
ti_press
        lda #MIX3_DP
        tfr a,dp
        jsr MIX3_BUF
        clra
        tfr a,dp
        else
ti_press
        ldy #tune0_notes
ti_tloop
        jsr pt_step               ; shared with play_tune -- one place
        bne ti_tkey               ; that knows note/rest/terminator
        ldy #tune0_notes          ; tune finished: loop it
        bra ti_tloop
ti_tkey
        jsr scankeys
        lda keyflags
        anda #16
        beq ti_tloop
        endif
ti_release
        jsr scankeys
        lda keyflags
        anda #16
        bne ti_release

        rts

; T0231: show_title_resident -- the tape build's game-over title replay
; (X-ALL.TXT fidelity: `quitted` does `jp titlescreen`; TAPE_ROOMS builds
; restore that instead of T0146's text GAME OVER box). Copies the
; resident packed title-image+music blob (title_resident_lz.asm, in the
; tape-only region, TITLE_RESIDENT_LZ/TITLE_RESIDENT_LEN) into
; TITLE_LZ_BUF -- exactly where show_title's own gather loop would have
; left it -- then falls into the SAME unpack/transpose/wait code
; show_title uses from ti_gathered's music unpack onward (ti_transpose,
; above), so there is only one place that draws the title. Does NOT call
; unpack_c/unpack_d: block C/D are boot-once (see their own headers) and
; must not be touched again mid-game.
;
; Gated on TAPE_ROOMS: the -run build has no resident copy of the title
; stream at all (T0146 freed it) and keeps msg_gameover unchanged.
        if TAPE_ROOMS
show_title_resident
        lbsr title_copy_resident

        ldu #TITLE_LZ_BUF
        ldy #$6000
        jsr lz_unpack

        if TITLE_MIX3
        ldu #TITLE_LZ_BUF+TITLE_LZ_LEN
        ldy #MIX3_BUF
        jsr lz_unpack
        endif
        jmp ti_transpose

; T0219: shared by show_title (boot gather, tape build) and
; show_title_resident (game-over replay): copy the resident packed
; title+music blob to TITLE_LZ_BUF. On return U = TITLE_LZ_BUF +
; TITLE_RESIDENT_LEN (where block C's fragment gather continues).
; Clobbers X, D, U, ti_len.
        if FLOPPY
; T0241 (FLOPPY): the packed title+music blob is NOT resident any more: it is overlay OVL_TITLE
; in DIZZY.OVL (the 3266 B this frees are the point of the floppy build).  Same contract as the
; copy it replaces: the stream ends up at TITLE_LZ_BUF.  If the disk cannot be read (removed,
; wrong disk, ...) the title is SKIPPED: unwind this call AND show_title / show_title_resident
; (both call us with lbsr as their first act) so their caller carries on into the game.
title_copy_resident
        ldx #TITLE_LZ_BUF
        lda #OVL_TITLE
        jsr ovl_load
        tsta
        beq tr_ok
        leas 2,s                  ; drop our return address: straight back to show_title's caller
tr_ok   rts
        else
title_copy_resident
        ldx #TITLE_RESIDENT_LZ
        ldu #TITLE_LZ_BUF
        ldd #TITLE_RESIDENT_LEN
        std ti_len
tr_copy
        lda ,x+
        sta ,u+
        ldd ti_len
        subd #1
        std ti_len
        bne tr_copy
        rts
        endif
        endif
