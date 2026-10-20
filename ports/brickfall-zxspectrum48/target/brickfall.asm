; Brickfall -- ZX Spectrum 48K build. sjasmplus.
;
; Simulation is bit-exact with games/brickfall/recipe/model (see recipe README,
; "Resolved ambiguities") and follows ports/brickfall-c64/target/brickfall.asm
; step for step. Rendering and sound are additive, read-only views of the sim:
; see the "video" and "sound" sections (bitmap bricks/ball/paddle, ROM-font HUD,
; beeper effects inferred from the published state).
;
; Harness contract (recipe README "State contract" / "Input contract"):
;   gpf_state  16 bytes, updated at the END of every simulation step
;   gpf_bricks  5 bytes, directly after gpf_state
;   gpf_input_ret  the RET of read_input; A = buttons (1 LEFT, 2 RIGHT, 4 FIRE)
; The shipped build has no test-only code path: the harness overwrites A at
; gpf_input_ret from the outside.

        DEVICE ZXSPECTRUM48

; ---------------------------------------------------------------- constants
ATTR        = $5800

; Published state: plain RAM clear of screen ($4000-$5AFF), system variables
; ($5C00-$5CB5), code ($8000-) and the IM2 table/ISR ($FC00-$FDFF).
gpf_state   = $F000
gpf_bricks  = $F010

; Working copy, same layout; the sim mutates this and publish copies 21 bytes.
W_STEP      = $F020     ; 2
W_MODE      = $F022
W_LIVES     = $F023
W_SCORE     = $F024     ; 2
W_PX        = $F026
W_CLR       = $F027
W_BX        = $F028     ; 2  8.8
W_BY        = $F02A     ; 2  8.8
W_VX        = $F02C     ; 2  signed 8.8
W_VY        = $F02E     ; 2  signed 8.8
W_BRK       = $F030     ; 5

BTN         = $F040
T_COL       = $F041
T_MASK      = $F042
T_SIGN      = $F043
T_N         = $F044
PREV_BX     = $F045     ; last drawn ball (PREV_BY = $FF: nothing drawn)
PREV_BY     = $F046
PREV_PX     = $F047     ; last drawn paddle ($FF: nothing drawn)

STACK       = $FFF0

MODE_WAIT   = 0
MODE_PLAY   = 1
MODE_OVER   = 2
MODE_WON    = 3

VY_LAUNCH   = $FE80     ; -0x0180
VX_LEFT     = $FF80     ; -0x0080
VX_RIGHT    = $0080

; ---------------------------------------------------------------- code
        ORG $8000
start:
        di
        ld sp,STACK
        ld a,$FC
        ld i,a
        im 2                    ; vector table $FC00.., every vector = $FDFD
        call init_video
        call init_state
        call publish
        call snd_init
        call render
        ei
mainloop:
        halt                    ; frame sync: one sim step per 50 Hz interrupt
        call read_input
        ld (BTN),a
        call sim_step
        call publish
        call render
        call sound              ; beeper slice (events inferred from gpf_state)
        jr mainloop

; ---------------------------------------------------------------- input
; Returns buttons in A: 1 LEFT, 2 RIGHT, 4 FIRE.
;   keys: Z or Q = left, X or A = right, SPACE = fire,
;   Sinclair joystick 2 (keys 6 left, 7 right, 0 fire).
; Kempston ($1F) deliberately not read: on a plain 48K the port floats and
; returns screen data, which would inject phantom input.
read_input:
        ld d,0
        ld bc,$FEFE             ; row CAPS..V: Z = bit 1, X = bit 2
        in a,(c)
        bit 1,a
        jr nz,.n1
        set 0,d
.n1:    bit 2,a
        jr nz,.n2
        set 1,d
.n2:    ld b,$FB                ; row Q..T: Q = bit 0
        in a,(c)
        bit 0,a
        jr nz,.n3
        set 0,d
.n3:    ld b,$FD                ; row A..G: A = bit 0
        in a,(c)
        bit 0,a
        jr nz,.n4
        set 1,d
.n4:    ld b,$7F                ; row SPACE..B: SPACE = bit 0
        in a,(c)
        bit 0,a
        jr nz,.n5
        set 2,d
.n5:    ld b,$EF                ; row 0..6: 0 = bit 0, 7 = bit 3, 6 = bit 4
        in a,(c)
        bit 0,a
        jr nz,.n6
        set 2,d
.n6:    bit 3,a
        jr nz,.n7
        set 1,d
.n7:    bit 4,a
        jr nz,.n8
        set 0,d
.n8:    ld a,d
gpf_input_ret:
        ret

; ---------------------------------------------------------------- state
init_state:
        ld hl,W_STEP
        ld de,W_STEP+1
        ld bc,20
        ld (hl),0
        ldir                    ; zero the 21-byte work block
        ld a,3
        ld (W_LIVES),a
        ld a,112
        ld (W_PX),a
        ld hl,W_BRK
        ld b,5
        ld a,$ff
.b:     ld (hl),a
        inc hl
        djnz .b
        ld a,$ff
        ld (PREV_BY),a
        ld (PREV_PX),a
        ; fall through
attach:                         ; ball on the paddle, velocity 0
        ld hl,0
        ld (W_VX),hl
        ld (W_VY),hl
        xor a
        ld (W_BX),a
        ld (W_BY),a
        ld a,(W_PX)
        add a,14
        ld (W_BX+1),a
        ld a,172
        ld (W_BY+1),a
        ret

publish:                        ; working copy -> gpf_state + gpf_bricks (21 bytes)
        ld hl,W_STEP
        ld de,gpf_state
        ld bc,21
        ldir
        ret

; ---------------------------------------------------------------- simulation
sim_step:
        ld hl,(W_STEP)
        inc hl
        ld (W_STEP),hl
        ld a,(W_MODE)
        cp MODE_OVER
        ret nc                  ; OVER / WON freeze everything but step
        ; paddle: LEFT only / RIGHT only move 4 px, clamped; both cancel
        ld a,(W_PX)
        ld c,a
        ld a,(BTN)
        and 3
        cp 1
        jr nz,.notleft
        ld a,c
        sub 4
        jr nc,.stl
        xor a
.stl:   ld (W_PX),a
        jr .moved
.notleft:
        cp 2
        jr nz,.moved
        ld a,c
        add a,4
        cp 225
        jr c,.str
        ld a,224
.str:   ld (W_PX),a
.moved:
        ld a,(W_MODE)
        or a
        jr nz,.play
        ; ---- WAIT: re-attach, FIRE launches (ball does not move this step)
        call attach
        ld a,(BTN)
        and 4
        ret z
        ld hl,VY_LAUNCH
        ld (W_VY),hl
        ld a,(BTN)
        and 1
        jr z,.chkr
        ld hl,VX_LEFT
        ld (W_VX),hl
        jr .launched
.chkr:  ld a,(BTN)
        and 2
        jr z,.launched
        ld hl,VX_RIGHT
        ld (W_VX),hl
.launched:
        ld a,MODE_PLAY
        ld (W_MODE),a
        ret

.play:
        ; ---- move x. carry => result >= 0 ; no carry with vx<0 => negative.
        ld hl,(W_BX)
        ld de,(W_VX)
        add hl,de
        jr c,.xrange
        bit 7,d
        jr z,.xrange
        ld hl,0                 ; x < 0: clamp, vx = |vx|
        ld (W_BX),hl
        or a
        sbc hl,de               ; hl = -vx
        ld (W_VX),hl
        jr .xdone
.xrange:
        ld (W_BX),hl            ; x > 252<<8 ($FC00): clamp, vx = -|vx|
        ld de,$FC01
        or a
        sbc hl,de
        jr c,.xdone
        ld hl,$FC00
        ld (W_BX),hl
        ld de,(W_VX)
        ld hl,0
        or a
        sbc hl,de
        ld (W_VX),hl
.xdone:
        ; ---- move y, top wall only
        ld hl,(W_BY)
        ld de,(W_VY)
        add hl,de
        ld (W_BY),hl
        jr c,.ydone
        bit 7,d
        jr z,.ydone
        ld hl,0                 ; y < 0: clamp, vy = |vy|
        ld (W_BY),hl
        or a
        sbc hl,de
        ld (W_VY),hl
.ydone:
        ; ---- paddle: vy > 0, 172 <= by < 184, x overlap [px-3 .. px+31]
        ld hl,(W_VY)
        bit 7,h
        jr nz,.nopad
        ld a,h
        or l
        jr z,.nopad
        ld a,(W_BY+1)
        cp 172
        jr c,.nopad
        cp 184
        jr nc,.nopad
        ld a,(W_BX+1)
        ld b,a                  ; b = bx
        ld a,(W_PX)
        ld c,a                  ; c = px
        ld a,b
        add a,3                 ; bx+3 >= px  (bx+4 > px)
        cp c
        jr c,.nopad
        ld a,c
        add a,32                ; bx < px+32 (always true if px+32 = 256)
        jr c,.xok
        ld d,a
        ld a,b
        cp d
        jr nc,.nopad
.xok:
        xor a                   ; y = 172<<8
        ld (W_BY),a
        ld a,172
        ld (W_BY+1),a
        ld hl,(W_VY)            ; vy > 0 here, so -|vy| == -vy
        ex de,hl
        ld hl,0
        or a
        sbc hl,de
        ld (W_VY),hl
        ld a,b                  ; zone = clamp(bx+2-px, 0, 31) >> 3
        add a,2
        sub c
        jr nc,.zpos
        xor a
.zpos:  cp 32
        jr c,.zok
        ld a,31
.zok:   srl a
        srl a
        srl a
        add a,a
        ld e,a
        ld d,0
        ld hl,zone_vx
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld (W_VX),de
.nopad:
        ; ---- bricks: first overlapped, row-major, at most one
        ld a,(W_BY+1)
        ld e,a                  ; e = by
        ld a,(W_BX+1)
        ld d,a                  ; d = bx
        ld bc,0                 ; c = row, b = 0
.rowloop:
        ld hl,rowthr            ; row overlaps iff 0 <= by-(21+8r) < 11
        add hl,bc
        ld a,e
        sub (hl)
        jr c,.nextrow
        cp 11
        jr nc,.nextrow
        ld a,d                  ; col = bx>>5; col+1 too if (bx&31) >= 29
        srl a
        srl a
        srl a
        srl a
        srl a
        ld (T_COL),a
        call testbit
        jr nz,.hit
        ld a,d
        and 31
        cp 29
        jr c,.nextrow
        ld a,(T_COL)
        inc a
        cp 8
        jr nc,.nextrow
        ld (T_COL),a
        call testbit
        jr nz,.hit
.nextrow:
        inc c
        ld a,c
        cp 5
        jr nz,.rowloop
        jr .nobrick
.hit:
        ld a,(T_MASK)           ; clear the bit (known set); hl = &W_BRK[row]
        xor (hl)
        ld (hl),a
        ld hl,rowscore          ; score += 50 - 10*row
        add hl,bc
        ld e,(hl)
        ld d,0
        ld hl,(W_SCORE)
        add hl,de
        ld (W_SCORE),hl
        ld hl,W_CLR
        inc (hl)
        ld hl,(W_VY)            ; vy flips (plain negation)
        ex de,hl
        ld hl,0
        or a
        sbc hl,de
        ld (W_VY),hl
        ld a,(W_CLR)            ; every 10th brick: |vy| += $40, max $300
.mod10: sub 10
        jr z,.speed
        jr nc,.mod10
        jr .nobrick
.speed:
        ld hl,(W_VY)
        ld a,h
        ld (T_SIGN),a
        bit 7,h
        jr z,.pos
        ex de,hl
        ld hl,0
        or a
        sbc hl,de               ; hl = |vy|
.pos:   ld de,$40
        add hl,de
        ld de,$301
        push hl
        or a
        sbc hl,de
        pop hl
        jr c,.spdok
        ld hl,$300
.spdok: ld a,(T_SIGN)
        bit 7,a
        jr z,.spdst
        ex de,hl
        ld hl,0
        or a
        sbc hl,de
.spdst: ld (W_VY),hl
.nobrick:
        ; ---- win (checked before miss), then miss
        ld hl,W_BRK
        ld a,(hl)
        inc hl
        or (hl)
        inc hl
        or (hl)
        inc hl
        or (hl)
        inc hl
        or (hl)
        jr nz,.notwon
        ld a,MODE_WON
        ld (W_MODE),a
        ret
.notwon:
        ld a,(W_BY+1)
        cp 193                  ; (y>>8) > 192
        ret c
        ld hl,W_LIVES
        dec (hl)
        jr nz,.towait
        ld a,MODE_OVER
        ld (W_MODE),a
        ld hl,0
        ld (W_VX),hl
        ld (W_VY),hl
        ret
.towait:
        xor a                   ; MODE_WAIT
        ld (W_MODE),a
        jp attach

; in: c = row, T_COL = column. out: NZ if the brick is present;
; hl = &W_BRK[row], T_MASK = its bit. Preserves bc, de.
testbit:
        push de
        ld hl,bitmask
        ld a,(T_COL)
        ld e,a
        ld d,0
        add hl,de
        ld a,(hl)
        ld (T_MASK),a
        ld hl,W_BRK
        ld e,c
        add hl,de
        and (hl)
        pop de
        ret

zone_vx:    DW $FE80, $FF40, $00C0, $0180   ; -0x180 -0xC0 +0xC0 +0x180
rowthr:     DB 21, 29, 37, 45, 53           ; 21 + 8*row
rowscore:   DB 50, 40, 30, 20, 10
bitmask:    DB 1, 2, 4, 8, 16, 32, 64, 128

; ---------------------------------------------------------------- video
; Everything below is RENDER-ONLY: it reads the sim's working copy (W_*) and the
; published state, and writes only the screen, the border/beeper port and the
; R_*/S_*/SND_* variables ($F050+). It never writes gpf_state or any sim variable.
;
; Attribute-clash design (see NOTES.md): each 8x8 cell has ONE ink + ONE paper.
;  - paper is black everywhere; only INK carries colour, so a pixel sprite
;    drawn into a cell can never change what the neighbouring cells look like.
;  - bricks are 4 cells wide x 1 cell high (aligned to the 32x8 sim bricks, char
;    rows 3-7): bitmap pixels with a 1 px gap on the right and bottom, ink =
;    the row's bright colour, written once and cleared when the brick dies.
;  - ball (4x4) and paddle (32x8) are XOR-drawn pixels; no attribute is ever
;    written for them. A sprite takes the ink of whatever cell it is in.
; Flicker/tearing: XOR erase+redraw happens right after HALT, while the beam is
; still in the top border (~14000 T before the first pixel line). Only what moved
; is touched.
BORDER      = 1                 ; blue frame

R_BRK       = $F050             ; 5   bricks as last rendered (0 = none drawn)
R_SCORE     = $F055             ; 2   last rendered ($FFFF = force)
R_LIVES     = $F057
R_MODE      = $F058
R_ROW       = $F059
R_BIT       = $F05A
R_NEW       = $F05B
R_DIFF      = $F05C
R_SH        = $F05D
R_N         = $F05E
R_DIRTY     = $F05F
R_PB        = $F060             ; 5   shifted paddle row
R_NBY       = $F066             ; wanted ball y ($FF = hidden)
R_NEED      = $F067
R_VAL       = $F068             ; 2
S_PREV      = $F070             ; 21  previous published state (sound events)
SND_PTR     = $F090             ; 2   next (delay,count) pair, 0 = silent
SND_ID      = $F092

init_video:
        ld a,BORDER
        out ($FE),a
        ld hl,$4000
        ld de,$4001
        ld bc,6143
        ld (hl),0
        ldir                    ; clear pixels
        ld hl,ATTR
        ld de,ATTR+1
        ld bc,767
        ld (hl),$47             ; bright white ink on black
        ldir
        ld hl,R_BRK             ; render state: nothing drawn yet
        ld de,R_BRK+1
        ld bc,$F093-R_BRK-1
        ld (hl),0
        ldir
        ld hl,$FFFF
        ld (R_SCORE),hl
        ld a,$FF
        ld (R_LIVES),a
        ld (R_MODE),a
        ; attributes: score yellow, lives green, rule line blue, paddle row cyan
        ld hl,ATTR+1
        ld de,ATTR+2
        ld bc,10
        ld (hl),$46
        ldir
        ld hl,ATTR+24
        ld de,ATTR+25
        ld bc,6
        ld (hl),$44
        ldir
        ld hl,ATTR+2*32
        ld de,ATTR+2*32+1
        ld bc,31
        ld (hl),$41
        ldir
        ld hl,ATTR+22*32
        ld de,ATTR+22*32+1
        ld bc,31
        ld (hl),$45
        ldir
        ; rule line under the HUD (pixel row 16)
        ld hl,$4040
        ld de,$4041
        ld bc,31
        ld (hl),$FF
        ldir
        ; static HUD text
        ld de,$4001
        ld hl,s_score
        call print_str
        ld de,$4018
        ld hl,s_lives
        jp print_str

s_score:    DB "SCORE",0
s_lives:    DB "LIVES",0

; in: A = char 32..127, DE = cell address (pixel line 0). out: DE = next cell.
; Font bitmaps come from the machine's own ROM ($3D00 = ' ').
print_char:
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        ld bc,$3C00             ; (c-32)*8 + $3D00
        add hl,bc
        push de
        ld b,8
.l:     ld a,(hl)
        ld (de),a
        inc hl
        inc d
        djnz .l
        pop de
        inc de
        ret

print_str:                      ; HL = 0-terminated string, DE = cell
        ld a,(hl)
        or a
        ret z
        inc hl
        push hl
        call print_char
        pop hl
        jr print_str

; ---------------------------------------------------------------- render
render:
        ; ---- what changed?  dirty = bricks / score / lives / mode
        xor a
        ld (R_DIRTY),a
        ld hl,W_BRK
        ld de,R_BRK
        ld b,5
.cb:    ld a,(de)
        cp (hl)
        jr nz,.dirty
        inc hl
        inc de
        djnz .cb
        ld hl,(W_SCORE)
        ld de,(R_SCORE)
        or a
        sbc hl,de
        jr nz,.dirty
        ld a,(W_LIVES)
        ld hl,R_LIVES
        cp (hl)
        jr nz,.dirty
        ld a,(W_MODE)
        ld hl,R_MODE
        cp (hl)
        jr z,.clean
.dirty: ld a,1
        ld (R_DIRTY),a
.clean:
        ; ---- ball wanted position; hidden when it would leave the bitmap
        ld a,(W_BY+1)
        cp 189                  ; 4 rows must fit above y=192
        jr c,.vis
        ld a,$FF
.vis:   ld (R_NBY),a
        ld b,a
        ld a,(R_DIRTY)
        ld (R_NEED),a
        ld a,(PREV_BY)
        cp b
        jr nz,.moved
        cp $FF
        jr z,.same
        ld a,(PREV_BX)
        ld c,a
        ld a,(W_BX+1)
        cp c
        jr z,.same
.moved: ld a,1
        ld (R_NEED),a
.same:
        ; ---- erase the ball first: later non-XOR writes (bricks, text) must
        ;      not meet a drawn ball, or the XOR erase would leave debris
        ld a,(R_NEED)
        or a
        jr z,.noeb
        ld a,(PREV_BY)
        cp $FF
        jr z,.noeb
        ld b,a
        ld a,(PREV_BX)
        ld c,a
        call draw_ball
        ld a,$FF
        ld (PREV_BY),a
.noeb:
        ld a,(R_DIRTY)
        or a
        jr z,.nodirty
        call draw_bricks
        call draw_hud
.nodirty:
        ; ---- paddle (XOR, order vs ball irrelevant)
        ld a,(PREV_PX)
        ld hl,W_PX
        cp (hl)
        jr z,.nopad
        cp $FF
        jr z,.nep
        ld c,a
        call draw_paddle
.nep:   ld a,(W_PX)
        ld (PREV_PX),a
        ld c,a
        call draw_paddle
.nopad:
        ; ---- ball
        ld a,(R_NEED)
        or a
        ret z
        ld a,(R_NBY)
        cp $FF
        ret z
        ld (PREV_BY),a
        ld b,a
        ld a,(W_BX+1)
        ld (PREV_BX),a
        ld c,a
        jp draw_ball

; ---------------------------------------------------------------- bricks
; Draw/erase every brick whose bit differs from R_BRK; R_BRK follows W_BRK.
draw_bricks:
        xor a
        ld (R_ROW),a
.row:   ld a,(R_ROW)
        ld e,a
        ld d,0
        ld hl,W_BRK
        add hl,de
        ld a,(hl)
        ld (R_NEW),a
        ld b,a
        ld hl,R_BRK
        add hl,de
        ld a,(hl)
        xor b
        ld (R_DIFF),a
        ld (hl),b
        or a
        jr z,.nextrow
        xor a
        ld (R_BIT),a
.bit:   ld a,(R_NEW)
        srl a
        ld (R_NEW),a
        sbc a,a                 ; $FF = brick present now
        ld c,a
        ld a,(R_DIFF)
        srl a
        ld (R_DIFF),a
        jr nc,.nextbit
        ld a,(R_ROW)            ; offset = row*32 + col*4 (col = bit)
        rrca
        rrca
        rrca
        ld b,a
        ld a,(R_BIT)
        add a,a
        add a,a
        add a,b
        ld e,a
        ld d,0
        push bc
        push de
        ld hl,$4060             ; char row 3, col 0
        add hl,de
        ld a,c
        or a
        ld de,0                 ; erase: all-zero bitmap
        jr z,.pp
        ld d,$FF                ; cells 0-2 full, cell 3 leaves a 1 px gap
        ld e,$FE
.pp:    call brick_pix
        pop de
        pop bc
        ld hl,ATTR+3*32
        add hl,de
        ld a,c
        or a
        ld a,$47
        jr z,.sa
        push hl
        ld a,(R_ROW)
        ld e,a
        ld d,0
        ld hl,rowattr
        add hl,de
        ld a,(hl)
        pop hl
.sa:    ld b,4
.fa:    ld (hl),a
        inc hl
        djnz .fa
.nextbit:
        ld a,(R_BIT)
        inc a
        ld (R_BIT),a
        cp 8
        jr nz,.bit
.nextrow:
        ld a,(R_ROW)
        inc a
        ld (R_ROW),a
        cp 5
        jp nz,.row
        ret

; HL = first cell bitmap address, D = byte for cells 0-2, E = byte for cell 3.
; Pixel lines 0-6 get the byte, line 7 is the 1 px gap.
brick_pix:
        ld b,4
.k:     push hl
        ld a,b
        cp 1
        ld a,d
        jr nz,.s
        ld a,e
.s:     ld c,7
.ln:    ld (hl),a
        inc h
        dec c
        jr nz,.ln
        ld (hl),0
        pop hl
        inc hl
        djnz .k
        ret

; ---------------------------------------------------------------- HUD text
draw_hud:
        ld hl,(W_SCORE)
        ld de,(R_SCORE)
        or a
        sbc hl,de
        jr z,.noscore
        ld hl,(W_SCORE)
        ld (R_SCORE),hl
        ld (R_VAL),hl
        ld de,$4007
        ld ix,pow10
        ld a,5
        ld (R_N),a
.dig:   ld hl,(R_VAL)
        ld c,(ix+0)
        ld b,(ix+1)
        ld a,'0'-1
.sub:   inc a
        or a
        sbc hl,bc
        jr nc,.sub
        add hl,bc
        ld (R_VAL),hl
        call print_char
        inc ix
        inc ix
        ld a,(R_N)
        dec a
        ld (R_N),a
        jr nz,.dig
.noscore:
        ld a,(W_LIVES)
        ld hl,R_LIVES
        cp (hl)
        jr z,.nolives
        ld (hl),a
        add a,'0'
        ld de,$401E
        call print_char
.nolives:
        ld a,(W_MODE)
        ld hl,R_MODE
        cp (hl)
        ret z
        ld (hl),a
        ld e,a
        ld d,0
        ld hl,msg_attr
        add hl,de
        ld a,(hl)               ; message ink for this mode
        ld hl,ATTR+14*32+8
        ld b,16
.ma:    ld (hl),a
        inc hl
        djnz .ma
        ld a,(W_MODE)
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld de,msgs
        add hl,de
        ld de,$48C8             ; char row 14, col 8
        ld b,16
.mc:    ld a,(hl)
        inc hl
        push hl
        push bc
        call print_char
        pop bc
        pop hl
        djnz .mc
        ret

pow10:      DW 10000,1000,100,10,1
msg_attr:   DB $45,$47,$42,$44
msgs:       DB " SPACE: LAUNCH  "        ; WAIT
            DB "                "        ; PLAY
            DB "   GAME  OVER   "        ; OVER
            DB "    YOU  WIN    "        ; WON

; bright ink per brick row (top row = worth most): red yellow green cyan magenta
rowattr:    DB $42, $46, $44, $45, $43

; ---------------------------------------------------------------- sprites
; in: b = y, c = x (pixels). out: hl = bitmap address of (x&$F8, y). Clobbers a.
pixaddr:
        ld a,b
        and $C0
        rrca
        rrca
        rrca
        ld h,a
        ld a,b
        and 7
        or h
        or $40
        ld h,a
        ld a,b
        rlca
        rlca
        and $E0
        ld l,a
        ld a,c
        rrca
        rrca
        rrca
        and $1F
        or l
        ld l,a
        ret

; XOR the 4x4 ball (round-ish) at (x = c, y = b).
draw_ball:
        ld ix,ball_pat
        ld a,c
        and 7
        ld (R_SH),a
        ld a,4
        ld (R_N),a
.line:  ld d,(ix+0)
        ld e,0
        ld a,(R_SH)
        or a
        jr z,.go
        push bc
        ld b,a
.sh:    srl d
        rr e
        djnz .sh
        pop bc
.go:    call pixaddr
        ld a,(hl)
        xor d
        ld (hl),a
        inc hl
        ld a,(hl)
        xor e
        ld (hl),a
        inc b
        inc ix
        ld a,(R_N)
        dec a
        ld (R_N),a
        jr nz,.line
        ret

ball_pat:   DB $60,$F0,$F0,$60

; XOR the 32x8 paddle (rounded ends) at x = c, y = 176. Row patterns are 4
; bytes, shifted right by x&7 into the 5-byte buffer R_PB.
draw_paddle:
        ld ix,paddle_pat
        ld a,c
        and 7
        ld (R_SH),a
        ld b,176
        ld a,8
        ld (R_N),a
.line:  ld a,(ix+0)
        ld (R_PB),a
        ld a,(ix+1)
        ld (R_PB+1),a
        ld a,(ix+2)
        ld (R_PB+2),a
        ld a,(ix+3)
        ld (R_PB+3),a
        xor a
        ld (R_PB+4),a
        ld a,(R_SH)
        or a
        jr z,.go
        push bc
.sh:    ld hl,R_PB
        srl (hl)
        inc hl
        rr (hl)
        inc hl
        rr (hl)
        inc hl
        rr (hl)
        inc hl
        rr (hl)
        dec a
        jr nz,.sh
        pop bc
.go:    call pixaddr
        ex de,hl                ; de = screen
        ld hl,R_PB
        ld a,5
.x:     push af
        ld a,(de)
        xor (hl)
        ld (de),a
        inc hl
        inc de
        pop af
        dec a
        jr nz,.x
        inc b
        inc ix
        inc ix
        inc ix
        inc ix
        ld a,(R_N)
        dec a
        ld (R_N),a
        jr nz,.line
        ret

paddle_pat: DB $3F,$FF,$FF,$FC
            DB $7F,$FF,$FF,$FE
            DB $FF,$FF,$FF,$FF
            DB $FF,$FF,$FF,$FF
            DB $FF,$FF,$FF,$FF
            DB $FF,$FF,$FF,$FF
            DB $7F,$FF,$FF,$FE
            DB $3F,$FF,$FF,$FC

; ---------------------------------------------------------------- sound
; Beeper effects, one slice per frame. Events are inferred by comparing the
; published gpf_state with last frame's copy (S_PREV); the sim is never touched.
; A slice is a blocking square-wave loop of ~28000 T (of ~70900 T per frame,
; after ~10000 T of sim+render), so it always ends before the next 50 Hz
; interrupt and the HALT cadence is kept. Longer effects = several frames.
;   gpf_state offsets: +2 mode, +3 lives, +7 cleared, +13 vx hi, +15 vy hi, +16.. bricks
; effect ids (higher wins): 1 side wall, 2 top wall, 3 paddle, 4..8 brick row 0..4,
;   9 miss, 10 game over, 11 win
SLICE_T     = 28000

        MACRO TONE dly
tone_n  DEFL SLICE_T/(13*dly+45)
        IF tone_n > 255
tone_n  DEFL 255
        ENDIF
        DB dly, tone_n
        ENDM

snd_init:
        ld hl,gpf_state
        ld de,S_PREV
        ld bc,21
        ldir
        ret

sound:
        ld c,0
        ld a,(S_PREV+2)
        cp MODE_PLAY
        jr nz,.nowall
        ld a,(gpf_state+2)
        cp MODE_PLAY
        jr nz,.nowall
        ld a,(gpf_state+13)     ; vx sign flip -> side wall
        ld hl,S_PREV+13
        xor (hl)
        jp p,.novx
        ld c,1
.novx:  ld a,(gpf_state+15)     ; vy sign flip: now down = top wall, now up = paddle
        ld hl,S_PREV+15
        xor (hl)
        jp p,.nowall
        ld a,(gpf_state+15)
        bit 7,a
        ld c,3
        jr nz,.nowall
        ld c,2
.nowall:
        ld a,(gpf_state+7)      ; a brick was cleared: pitch by its row
        ld hl,S_PREV+7
        cp (hl)
        jr z,.nobrick
        ld hl,gpf_state+16
        ld de,S_PREV+16
        ld b,0
.fr:    ld a,(de)
        cp (hl)
        jr nz,.found
        inc hl
        inc de
        inc b
        ld a,b
        cp 5
        jr c,.fr
        ld b,4
.found: ld a,b
        add a,4
        ld c,a
.nobrick:
        ld a,(gpf_state+2)
        ld hl,S_PREV+2
        cp (hl)
        jr z,.nomode
        cp MODE_WON
        jr nz,.nw
        ld c,11
        jr .nomode
.nw:    cp MODE_OVER
        jr nz,.nov
        ld c,10
        jr .nomode
.nov:   or a                    ; back to WAIT = a miss (WAIT->PLAY launch is silent)
        jr nz,.nomode
        ld c,9
.nomode:
        push bc
        ld hl,gpf_state
        ld de,S_PREV
        ld bc,21
        ldir
        pop bc
        ld a,c
        or a
        jr z,.nostart
        ld hl,(SND_PTR)
        ld a,h
        or l
        jr z,.start
        ld a,(SND_ID)
        cp c
        jr z,.start
        jr nc,.nostart          ; a longer-priority effect is still playing
.start: ld a,c
        ld (SND_ID),a
        add a,a
        ld e,a
        ld d,0
        ld hl,sfx_tab
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld (SND_PTR),de
.nostart:
        ld hl,(SND_PTR)
        ld a,h
        or l
        ret z
        ld d,(hl)
        inc hl
        ld a,d
        or a
        jr nz,.go
        ld (SND_PTR),a          ; end marker: a = 0 -> low byte
        ld (SND_PTR+1),a
        ret
.go:    ld c,(hl)
        inc hl
        ld (SND_PTR),hl
        ; fall through: d = half-period delay, c = half-period count
play_slice:
        ld e,BORDER
.l:     ld a,e
        out ($FE),a
        ld b,d
.dl:    djnz .dl
        ld a,e
        xor $10                 ; beeper bit
        ld e,a
        dec c
        jr nz,.l
        ld a,BORDER
        out ($FE),a
        ret

sfx_tab:    DW 0, sfx_side, sfx_top, sfx_pad
            DW sfx_b0, sfx_b1, sfx_b2, sfx_b3, sfx_b4
            DW sfx_miss, sfx_over, sfx_win

sfx_side:   TONE 110
            TONE 110
            DB 0
sfx_top:    TONE 90
            TONE 90
            DB 0
sfx_pad:    TONE 75
            TONE 75
            DB 0
sfx_b0:     TONE 26
            TONE 26
            DB 0
sfx_b1:     TONE 34
            TONE 34
            DB 0
sfx_b2:     TONE 44
            TONE 44
            DB 0
sfx_b3:     TONE 56
            TONE 56
            DB 0
sfx_b4:     TONE 70
            TONE 70
            DB 0
sfx_miss:   TONE 60
            TONE 75
            TONE 90
            TONE 110
            TONE 135
            TONE 165
            TONE 200
            TONE 240
            DB 0
sfx_over:   TONE 90
            TONE 90
            TONE 90
            TONE 120
            TONE 120
            TONE 120
            TONE 160
            TONE 160
            TONE 160
            TONE 230
            TONE 230
            TONE 230
            TONE 230
            DB 0
sfx_win:    TONE 200
            TONE 200
            TONE 160
            TONE 160
            TONE 120
            TONE 120
            TONE 90
            TONE 90
            TONE 60
            TONE 60
            TONE 40
            TONE 40
            TONE 40
            TONE 40
            DB 0

code_end:
        ASSERT code_end < $F000

; ---------------------------------------------------------------- IM 2 plumbing
; I = $FC: the vector is read from $FCxx..; all 257 entries are $FD => ISR $FDFD.
        ORG $FC00
        DS 257,$FD
        ORG $FDFD
isr:    ei
        reti

        SAVESNA "brickfall.sna", start
