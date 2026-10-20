; Room 36 -- CARTRIDGE-BOOT VARIANT (diagnostic test, see NOTES.md
; "Cartridge-boot diagnostic"). Identical logic to room36.asm, but
; assembled to run at $C000 (mapped cartridge ROM space) and auto-started
; the way a real commercial CoCo cart boots -- straight from power-on,
; never passing through an active BASIC text-mode session first -- unlike
; room36.asm, which is CLOADM/EXEC'd into a BASIC session already showing
; text. Testing whether that boot-path difference is what's causing the
; display issue real commercial cartridges (e.g. Arkanoid) don't have.

FBBASE  equ $4000
FBWIDTH equ 32          ; bytes per screen row (256px / 8)

; Movement clamps: keep Dizzy's frame-0 sprite (24x21) fully on the
; 256x192 screen. Frame-specific (height 21) -- revisit if a different
; frame/animation with a different height is ever used here.
DIZZY_MAXX   equ 232    ; 256 - 24, already a multiple of 4
DIZZY_MAXY   equ 171    ; 192 - 21

DELAY_COUNT  equ 15000  ; crude, untuned frame-pacing spin count (see `delay`)

        org $c000

start
        lds #$2000      ; explicit stack pointer -- a cart boots before
                         ; BASIC has set one up (unlike room36.asm, which
                         ; runs CLOADM/EXEC'd into an already-initialized
                         ; BASIC session where S is already valid); our
                         ; code uses pshs/puls (blit_shifted et al) and a
                         ; garbage S corrupts memory instead of crashing
                         ; cleanly. $2000 chosen well clear of the RAM
                         ; variable block below ($0e00-ish, growing up) so
                         ; the downward-growing stack can't collide with it.
        orcc #$50       ; disable IRQ+FIRQ -- BASIC's own interrupt handler
                         ; (keyboard scan, cursor blink, ~60Hz) is still
                         ; installed and active since we never touched it;
                         ; left enabled, it can fire mid-loop during the
                         ; screen clear/blit and interfere with SAM/PIA
                         ; state we depend on. Only visible at real-time
                         ; execution speed, not under -no-ratelimit (which
                         ; races through faster than one IRQ tick) -- see
                         ; NOTES.md "Slice: room 36" for the full story.

        ; --- SAM V0-V2 = 110 (6R/6C mode family) ---
        ; STA not LDA -- see room36.asm for why.
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

        ; --- PIA1 $FF22: mode nibble=$F (A/G=1, GM=111 = RG6, 256x192x1bpp
        ; = PMODE4) plus CSS=1 (bit3). $E (GM=110) is CG6, a 128x192
        ; FOUR-COLOUR mode -- see room36.asm and NOTES.md T0028. ---
        lda $ff22
        anda #$07
        ora #$f8
        sta $ff22

        ; --- Dizzy's real spawn point for this room (46,168), per the main
        ; loop's resetlives block (NOTES.md T0011). ---
        lda #46
        sta dizzy_x
        lda #168
        sta dizzy_y

        ; SAM/PIA must be set BEFORE the graphics data is written -- see
        ; room36.asm for why (NOTES.md "known good books" section).
        jsr redraw

; --------------------------------------------------------------------
; mainloop (T0019): scan keys, move Dizzy (clamped to stay fully
; on-screen -- an off-screen blit would write past the 6144-byte
; framebuffer into unrelated memory, a real crash risk, not just a
; cosmetic one), redraw the whole scene, repeat. No edge-detection/
; debounce: a key held down keeps moving Dizzy every loop iteration,
; slowed only by `delay` -- good enough for a first playable pass, real
; debounce would need remembering last-frame's key state.
; --------------------------------------------------------------------
mainloop
        jsr scankeys

        lda keyflags
        bita #1                 ; up
        beq ml_noup
        lda dizzy_y
        cmpa #4
        blo ml_noup              ; clamp: don't go above y=0
        suba #4
        sta dizzy_y
ml_noup
        lda keyflags
        bita #2                 ; down
        beq ml_nodown
        lda dizzy_y
        cmpa #DIZZY_MAXY
        bhs ml_nodown            ; clamp: keep bottom edge on-screen
        adda #4
        sta dizzy_y
ml_nodown
        lda keyflags
        bita #4                  ; left
        beq ml_noleft
        lda dizzy_x
        cmpa #4
        blo ml_noleft            ; clamp: don't go left of x=0
        suba #4
        sta dizzy_x
ml_noleft
        lda keyflags
        bita #8                  ; right
        beq ml_noright
        lda dizzy_x
        cmpa #DIZZY_MAXX
        bhs ml_noright           ; clamp: keep right edge on-screen
        adda #4
        sta dizzy_x
ml_noright

        jsr redraw
        jsr delay

        lbra mainloop

; --------------------------------------------------------------------
; redraw: clear the framebuffer, draw every room placement, then Dizzy
; on top -- the whole-scene-every-frame approach this slice uses since
; there's no background-restore/erase mechanism yet (see NOTES.md
; "Slice: room 36" T0019 section for why, and what a real game would
; need instead).
; --------------------------------------------------------------------
redraw
        ldy #FBBASE
        ldx #6144
        clra
rd_clrlp
        sta ,y+
        leax -1,x
        bne rd_clrlp

        ldb room_place_count
        stb placecount
        ldx #room_placements
rd_placelp
        ldd ,x++
        std blit_ptr
        lda ,x+
        sta blit_x
        lda ,x+
        sta blit_y
        stx placeptr
        jsr blit
        ldx placeptr
        dec placecount
        bne rd_placelp

        jsr blitdizzy
        rts

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
        rts

; --------------------------------------------------------------------
; delay: crude fixed busy-wait so movement is human-controllable instead
; of instant. Not frame/vsync-synced -- a real game loop would tie this
; to the video timer, not a cycle-counted spin; fine for this slice.
; --------------------------------------------------------------------
delay
        ldd #DELAY_COUNT
delaylp
        subd #1
        bne delaylp
        rts

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
        ldu blit_ptr
        ldb 1,u         ; height (skip width byte at 0,u)
        stb blit_height
        lda 2,u         ; bytes_per_row
        sta blit_bpr
        leau 3,u        ; U -> bitmap data start
        stu blit_src

        ; dest_col = pixel_x >> 3 ; shift = pixel_x & 4 (0 or 4)
        lda blit_x
        anda #$04
        sta blit_shift
        lda blit_x
        lsra
        lsra
        lsra
        sta blit_col

        ; row_addr = FBBASE + y*32 + dest_col
        lda #FBWIDTH
        ldb blit_y
        mul             ; D = y * 32
        addd #FBBASE
        tfr d,x
        ldb blit_col
        abx             ; X += dest_col (zero-extended byte add)
        stx blit_row

        clr blit_r
blit_rowlp
        ldx blit_row
        ldu blit_src
        clr blit_c
        lda blit_shift
        bne blit_shifted

blit_alignedlp
        lda ,u+
        ora ,x
        sta ,x+
        inc blit_c
        ldb blit_c
        cmpb blit_bpr
        bne blit_alignedlp
        bra blit_nextrow

blit_shifted
        ; source byte's high nibble ORs into current dest byte's low
        ; nibble; low nibble ORs into next dest byte's high nibble.
blit_shiftedlp
        lda ,u+
        pshs a
        anda #$f0
        lsra
        lsra
        lsra
        lsra
        ora ,x
        sta ,x+
        puls a
        anda #$0f
        asla
        asla
        asla
        asla
        ora ,x
        sta ,x
        inc blit_c
        ldb blit_c
        cmpb blit_bpr
        bne blit_shiftedlp

blit_nextrow
        ldx blit_src
        ldb blit_bpr
        abx
        stx blit_src

        ldx blit_row
        ldb #FBWIDTH
        abx
        stx blit_row

        inc blit_r
        ldb blit_r
        cmpb blit_height
        bne blit_rowlp

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
;   dizzy_x, dizzy_y = destination top-left (set by caller before JSR)
; --------------------------------------------------------------------
blitdizzy
        ldb dizzy_frame_h
        stb bd_height

        lda #FBWIDTH
        ldb dizzy_y
        mul                     ; D = y * 32
        addd #FBBASE
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

        ldu #dizzy_frame_mask
        stu bd_maskptr
        ldu #dizzy_frame_sprite
        stu bd_spriteptr

        clr bd_r
bd_rowlp
        ldx bd_row
        ldu bd_maskptr
        ldy bd_spriteptr

        lda bd_shift
        bne bd_rowshifted

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
        lbra bd_rowdone

; --- shifted by 4 (nibble): 4 dest bytes. Mask padding = $F (preserve)
; at the leading high nibble and trailing low nibble; sprite padding =
; $0 there (safe: XOR 0 is a no-op against the preserved bits). ---
bd_rowshifted
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

bd_rowdone
        stu bd_maskptr
        sty bd_spriteptr

        ldx bd_row
        ldb #FBWIDTH
        abx
        stx bd_row

        inc bd_r
        ldb bd_r
        cmpb bd_height
        lbne bd_rowlp

        rts

        include "room36_data.asm"
        include "dizzy_frame0.asm"

; --------------------------------------------------------------------
; Mutable state lives in RAM ($0e00+), NOT in this ROM image -- a real
; bug caught during cart-boot bring-up, not assumed away: everything
; above this point (code AND the room/sprite reference data) sits in
; ROM space ($C000+) and is read-only from the CPU's perspective. In
; room36.asm's DECB build these same `fcb 0`/`fdb 0` variable
; declarations lived in RAM (the whole program loads into RAM there), so
; writes to them worked fine; simply reusing the same declarations here
; put them in ROM instead, where every `sta`/`std` to them silently did
; nothing. That's what produced the "starts running, then falls apart"
; symptom the first cart-boot attempt showed -- not a crash, just state
; that never actually updated. `rmb` (reserve, not `fcb`/`fdb`) so this
; section costs zero ROM bytes, matching what these really are.
        org $0e00

placecount rmb 1
placeptr   rmb 2

blit_ptr    rmb 2
blit_x      rmb 1
blit_y      rmb 1
blit_height rmb 1
blit_bpr    rmb 1
blit_src    rmb 2
blit_col    rmb 1
blit_shift  rmb 1
blit_row    rmb 2
blit_r      rmb 1
blit_c      rmb 1

keyflags      rmb 1

dizzy_x       rmb 1
dizzy_y       rmb 1
bd_height     rmb 1
bd_row        rmb 2
bd_maskptr    rmb 2
bd_spriteptr  rmb 2
bd_r          rmb 1
bd_shift      rmb 1
bd_m0         rmb 1
bd_m1         rmb 1
bd_m2         rmb 1
bd_s0         rmb 1
bd_s1         rmb 1
bd_s2         rmb 1
bd_tm         rmb 1
bd_ts         rmb 1

        end start
