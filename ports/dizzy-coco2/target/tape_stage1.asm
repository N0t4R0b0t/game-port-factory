; tape_stage1.asm -- T0228 PHASE 2: the real custom tape loader.
;
; CLOADM-loaded (ordinary ROM-mode load, below $8000) at STAGE1_ORG, then
; EXEC'd. From there it reads the REST of the tape itself: a stream of
; (dest addr, chunk) segments -- today, exactly the SAME bytes today's
; -run/CLOADM path already loads (see tools/tape_pack.sh, which builds
; the segment stream straight from target/room36.bin's own DECB blocks,
; so this build is behaviourally IDENTICAL to today's until a real
; tape-only region is added) -- terminated by a sentinel (dest=$FFFF)
; whose "data" is the game's real entry address, which this jumps to.
;
; Mechanism proved standalone in tools/tapeloader_spike (T0226/T0227):
; CSRDON/BLKIN ($A004/$A006 ROM vectors), read into a low buffer in ROM
; mode, toggle $ffdf/$ffde around the copy-up ONLY for segments destined
; at $8000+ -- everything below $8000 is written DIRECTLY via CBUFAD
; (exactly what plain CLOADM already relies on system-wide, no buffer
; needed).
;
; T0229: CSRDON (CASON's full ~96-transition tone lock) is called
; EXACTLY ONCE, before the very first block, not per block -- mirrors
; the real ROM's own CLOADM exactly (LA52B calls CASON once, then loops
; on GETBLK alone at LA52E for every subsequent block of the file,
; confirmed from the disassembly, T0226). caswriter's
; write_segment_stream matches this on the write side: only its first
; block gets a full leader, everything after gets the short
; INTER_BLOCK_GAP a real CSAVEM writes between blocks of the same file
; (measured from a real xroar-encoded multi-block reference, T0229).
; This is what took target/room36.cas from 66558 bytes (262 full
; tone-lock leaders) down to close to the raw image size -- the earlier
; per-block CSRDON was correct but far more conservative than the real
; hardware protocol needs.
;
; WORKSPACE PLACEMENT (T0228 constraint from the brief): the existing
; load image now runs $0100..LOAD_END (~$7A61 as of this build, see
; tools/tape_pack.sh's own printed value -- it shifts as the game
; grows), and start: does not touch $7E00 (nibswap) until AFTER this
; code hands off control. So stage1 itself, AND its scratch buffers,
; live in the free tail gap [LOAD_END, $7E00) -- NOT $2000 (the
; standalone spike's buffer), which the real load image now occupies.
; tools/tape_pack.sh asserts this gap is big enough before assembling
; and fails loudly if a future build ever grows past it.
;
; No explicit stack setup needed here (matches the proven spike): S is
; whatever BASIC's EXEC left it as, sufficient for this code's own
; shallow JSR/BSR depth, and start: (the jump target) sets its own `lds
; #$0100` immediately, same as it always has.

CSRDON_VEC equ $A004
BLKIN_VEC  equ $A006
BLKTYP     equ $7C
BLKLEN     equ $7D
CBUFAD     equ $7E
CSRERR     equ $81

        org STAGE1_ORG

tape_stage1
        orcc #$50               ; GETBLK does this itself too, but keep
                                 ; interrupts off for this code's whole
                                 ; run, matching this port's own boot
                                 ; convention (T0226 GETBLK note).
        jsr [CSRDON_VEC]        ; T0229: ONE tone-lock for the WHOLE
                                 ; stream -- see this file's header note.
seg_loop
        ldx #hdr_buf
        stx CBUFAD
        jsr [BLKIN_VEC]
        lda CSRERR
        bne seg_err

        ldx hdr_buf              ; X = this segment's destination addr
        cmpx #$FFFF
        beq seg_done             ; sentinel: next block is the exec addr

        cmpx #$8000
        blo direct_seg

staged_seg
        pshs x                   ; save the real $8000+ destination
        ldx #stagebuf
        stx CBUFAD
        jsr [BLKIN_VEC]
        lda CSRERR
        bne seg_err

        lda hdr_buf+2            ; chunk length (1..255)
        sta copy_count
        ldx #stagebuf
        puls y                   ; Y = real destination, restored
        sta $ffdf                ; all-RAM: $8000+ is now genuine RAM
cp_loop
        lda ,x+
        sta ,y+
        dec copy_count
        bne cp_loop
        sta $ffde                ; ROM back for the next CSRDON/BLKIN
        bra seg_loop

direct_seg
        stx CBUFAD               ; write straight to the destination --
        jsr [BLKIN_VEC]          ; ROM-mode writes below $8000 always
        lda CSRERR               ; land in real RAM (unlike $8000+).
        bne seg_err
        bra seg_loop

seg_done
        ldx #hdr_buf
        stx CBUFAD
        jsr [BLKIN_VEC]          ; 2-byte exec address, big-endian
        lda CSRERR
        bne seg_err
        ldx hdr_buf
        jmp ,x                   ; hand off to the game's real entry

        ; No automatic retry: a tape read failure here means the whole
        ; load is unrecoverable anyway (unlike a CLOADM checksum retry
        ; loop, which can at least re-scan for the SAME named file --
        ; this stream has no names to re-find). Latch which segment
        ; failed for a GDB probe and halt visibly rather than run on
        ; with a corrupt image.
seg_err
        ldx hdr_buf
        stx err_addr
        lda #1
        sta err_flag
err_spin
        bra err_spin

hdr_buf     rmb 3                ; addr_hi, addr_lo, len
copy_count  rmb 1
err_flag    rmb 1
err_addr    rmb 2
stagebuf    rmb 255

STAGE1_END equ *

        end tape_stage1
