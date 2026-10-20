; tapeloader_spike/stage1.asm -- PHASE 1 standalone spike for a custom
; single-CLOADM tape loader that breaks the ~32.5KB load ceiling
; (factory/platforms/coco2.toml [load]).
;
; Loaded normally by CLOADM (below $8000, entirely ROM-mode-writable),
; this is EXEC'd by BASIC once loaded. It then keeps reading the SAME
; tape itself, past the EOF block CLOADM already consumed, using the
; ROM's own cassette block routines via their documented indirect
; vectors -- NOT hardcoded ROM addresses, so this survives ROM revision
; differences the way BASIC's own code does:
;
;   CSRDON = FDB [$A004]  turn on tape motor, lock onto leader tone
;   BLKIN  = FDB [$A006]  read one block into (CBUFAD), returns
;                         BLKTYP/BLKLEN/CSRERR ($7C/$7D/$81, direct page)
;
; Confirmed against an actual disassembly of source/roms/BASIC.ROM
; (Color BASIC 1.2), cross-checked byte-for-byte against "Color Basic
; Unravelled II"'s listing -- see NOTES.md for the addresses and the
; byte-level match.
;
; GETBLK (the routine BLKIN vectors to) does `orcc #$50` itself and
; reads/writes only zero-page workspace plus PIA1 ($FF20-23, unaffected
; by the SAM's TY bit) -- so it can be called with ROM still mapped
; regardless of whether interrupts were on, and needs no relocation to
; run: it is pure BSR/RTS, no absolute JMP, verified by inspection of
; the listing from GETBLK ($A70B) through its callees down to LA76C.
; This spike calls it directly, in ROM mode, into a LOW staging buffer
; (STAGE_BUF, below $8000, always genuine RAM regardless of the SAM's
; map type) -- Option A from the task brief, not Option B (relocating
; GETBLK itself into RAM to read directly while all-RAM is engaged).
; Option B is a legitimate follow-on optimisation (it removes the
; per-block ROM/RAM toggle) but is NOT needed to prove the mechanism,
; and staying in ROM mode while reading keeps every ROM cassette
; routine available exactly as it already is during a normal CLOADM.
;
; Per block: JSR [CSRDON] ; JSR [BLKIN] ; sta $ffdf (all-RAM) ; copy
; STAGE_BUF -> running dest pointer ; sta $ffde (ROM back) ; repeat.
; After the last block, this leaves all-RAM ENGAGED and the data
; resident at DEST_BASE.. -- exactly the state the real loader's stage 1
; must end in before jumping into the game (task brief, PHASE 1 step 3).
; This spike doesn't jump anywhere afterward: it just spins so a GDB
; probe can read memory and confirm the pattern landed correctly.

                org $3000

CSRDON_VEC      equ $A004
BLKIN_VEC       equ $A006
BLKTYP          equ $7C         ; direct-page workspace (Color BASIC 1.2)
BLKLEN          equ $7D
CBUFAD          equ $7E
CSRERR          equ $81

STAGE_BUF       equ $2000       ; low RAM staging buffer, one block
DEST_BASE       equ $8000       ; where the pattern must land
NBLOCKS         equ 41          ; ceil(8192/200)
RAW_BLOCK_SIZE  equ 200

; ok_flag / err_flag: left in low RAM (readable over GDB without racing
; the loop) so a probe can tell "still running" from "finished clean"
; from "a block's checksum/RAM-compare failed" without needing to catch
; the CPU mid-instruction.
OK_FLAG         equ $2F00       ; $01 once all NBLOCKS landed cleanly
ERR_FLAG        equ $2F01       ; last non-zero CSRERR seen, else 0
DONE_COUNT      equ $2F02       ; blocks completed so far (live progress)

start
                orcc #$50               ; disable IRQ/FIRQ for the whole load
                clr OK_FLAG
                clr ERR_FLAG
                clr DONE_COUNT

                ldy #DEST_BASE          ; running destination pointer
                pshs y                  ; keep it on the hardware stack
                ldb #NBLOCKS
                stb blk_count

read_loop
                ldx #STAGE_BUF
                stx CBUFAD

                jsr [CSRDON_VEC]        ; lock onto this block's leader
                jsr [BLKIN_VEC]         ; read it into STAGE_BUF

                lda CSRERR
                beq blk_ok
                sta ERR_FLAG
                bra spin                ; stop rather than copy bad data

blk_ok
                ; copy BLKLEN bytes from STAGE_BUF up to the dest
                ; pointer (on the hardware stack), toggling all-RAM
                ; only for the copy itself -- ROM must stay mapped for
                ; the NEXT jsr [CSRDON_VEC]/[BLKIN_VEC].
                lda BLKLEN
                sta copy_count
                ldx #STAGE_BUF
                puls y                  ; dest pointer back into Y

                sta $ffdf               ; engage all-RAM ($8000+ now RAM)
copy_loop
                lda ,x+
                sta ,y+
                dec copy_count
                bne copy_loop
                sta $ffde               ; ROM back for the next BLKIN

                pshs y                  ; save updated dest pointer

                inc DONE_COUNT
                dec blk_count
                bne read_loop

                puls y                  ; balance the stack
                lda #1
                sta OK_FLAG
                sta $ffdf               ; leave in all-RAM, data resident
                                        ; (PHASE 1 brief: stage 1 ends in
                                        ; all-RAM mode with data present)
spin
                bra spin

blk_count       fcb 0
copy_count      fcb 0

                end start
