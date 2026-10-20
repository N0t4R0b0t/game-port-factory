; Brickfall -- Tandy CoCo 2 (MC6809, PMODE 4 = 256x192 RG6) build. lwasm.
;
; The simulation is bit-exact with games/brickfall/recipe/model (recipe README,
; "Resolved ambiguities") and follows ports/brickfall-zxspectrum48/target/brickfall.asm
; step for step. The 6809 is big-endian, so the sim keeps its working copy (W_*)
; big-endian and `publish` byte-swaps into the little-endian gpf_state contract.
;
; Harness contract (recipe README "State contract" / "Input contract"):
;   gpf_state       16 bytes, little-endian, rewritten at the END of every sim step
;   gpf_bricks       5 bytes, directly after gpf_state
;   gpf_input_ret   the RTS of read_input; A = buttons (1 LEFT, 2 RIGHT, 4 FIRE)
; The shipped build has no test-only code path: the harness overwrites A at
; gpf_input_ret from the outside.
;
; Timing: NTSC fields come at 60 Hz, one sim step is 50 Hz. A fixed-step accumulator
; (add 5 per field, run a step and subtract 6 when >= 6) gives exactly 5 steps per 6
; fields, so the per-STEP trace is identical to the 50 Hz ports. The sim itself never
; looks at time. The field pulse is polled (PIA0 $FF03 bit 7); interrupts stay masked.
;
; Memory map (all below $8000: the stock DECB loader cannot write $8000+, see
; factory/platforms/coco2.toml [load]):
;   $1000-$10FF  variables (gpf_state $1000, gpf_bricks $1010, W_* $1020, R_* $1060)
;   $1100-$1EFF  stack (S = $1F00, grows down)
;   $2000-$37FF  PMODE 4 frame buffer (SAM F = 16)
;   $4000-       code + tables

; ---------------------------------------------------------------- constants
SCR         equ $2000

gpf_state   equ $1000
gpf_bricks  equ $1010

; Working copy, big-endian 16-bit fields. Same ORDER as gpf_state; 21 bytes.
W_STEP      equ $1020   ; 2
W_MODE      equ $1022
W_LIVES     equ $1023
W_SCORE     equ $1024   ; 2
W_PX        equ $1026
W_CLR       equ $1027
W_BX        equ $1028   ; 2  8.8 (first byte = integer pixel)
W_BY        equ $102A   ; 2  8.8
W_VX        equ $102C   ; 2  signed 8.8
W_VY        equ $102E   ; 2  signed 8.8
W_BRK       equ $1030   ; 5

BTN         equ $1040
ACC         equ $1041   ; 60 Hz -> 50 Hz accumulator
T_COL       equ $1042
T_MASK      equ $1043
T_SIGN      equ $1044
T_ROW       equ $1045
T_BX        equ $1046
T_BY        equ $1047
T_PX        equ $1048
T_X2        equ $1049

; render-only variables ($1060+): never read by the sim
R_BRK       equ $1060   ; 5  bricks as last rendered
R_SCORE     equ $1065   ; 2  last rendered ($FFFF = force)
R_LIVES     equ $1067   ; ($FF = force)
R_MODE      equ $1068   ; ($FF = force)
R_PX        equ $1069   ; last drawn paddle ($FF = none)
R_BX        equ $106A   ; last drawn ball ...
R_BY        equ $106B   ; ... (R_BY $FF = none drawn)
R_NEW       equ $106C
R_DIFF      equ $106D
R_BIT       equ $106E
R_COL       equ $106F
R_PB        equ $1070   ; 5  paddle row pattern
R_DIG       equ $1075   ; 4  score digits
T_N         equ $1079
T_ARG       equ $107A
T_MUL       equ $107B
T_M0        equ $107C
T_M1        equ $107D
T_L         equ $107E
T_P         equ $107F

STACK       equ $1F00

MODE_WAIT   equ 0
MODE_PLAY   equ 1
MODE_OVER   equ 2
MODE_WON    equ 3

VY_LAUNCH   equ $FE80   ; -0x0180
VX_LEFT     equ $FF80   ; -0x0080
VX_RIGHT    equ $0080

; ---------------------------------------------------------------- code
        org $4000
start:
        orcc #$50               ; IRQ + FIRQ masked for good (polled, never interrupt-driven)
        lds #STACK
        jsr init_video
        jsr init_state
        jsr publish
        jsr init_render
        jsr render
mainloop:
        lda $FF03               ; PIA0 CB1 = field sync, bit 7 set once per 60 Hz field
        bpl mainloop
        lda $FF02               ; reading side B clears the flag
        lda ACC
        adda #5
        cmpa #6
        blo noStep
        suba #6
        sta ACC
        jsr read_input
        sta BTN
        jsr sim_step
        jsr publish
        jsr render
        bra mainloop
noStep: sta ACC
        bra mainloop

; ---------------------------------------------------------------- input
; Returns buttons in A: 1 LEFT, 2 RIGHT, 4 FIRE. Keyboard matrix, row PA3
; ($FF00 bit 3, active low) with one column strobed low at a time on $FF02:
;   PB0 = X, PB2 = Z, PB5 = LEFT arrow, PB6 = RIGHT arrow, PB7 = SPACE.
;   left = Z or LEFT arrow, right = X or RIGHT arrow, fire = SPACE.
; The joystick is deliberately not read: its buttons share $FF00 bits 0-1 with
; keyboard rows 0-1, and an unplugged port floats (phantom input).
read_input:
        clrb
        lda #%11111110          ; column 0: X
        sta $FF02
        lda $FF00
        bita #8
        bne ri1
        orb #2
ri1:    lda #%11111011          ; column 2: Z
        sta $FF02
        lda $FF00
        bita #8
        bne ri2
        orb #1
ri2:    lda #%11011111          ; column 5: LEFT arrow
        sta $FF02
        lda $FF00
        bita #8
        bne ri3
        orb #1
ri3:    lda #%10111111          ; column 6: RIGHT arrow
        sta $FF02
        lda $FF00
        bita #8
        bne ri4
        orb #2
ri4:    lda #%01111111          ; column 7: SPACE
        sta $FF02
        lda $FF00
        bita #8
        bne ri5
        orb #4
ri5:    lda #$FF                ; release all columns
        sta $FF02
        tfr b,a
gpf_input_ret:
        rts

; ---------------------------------------------------------------- state
init_state:
        ldx #W_STEP
        ldb #21
is0:    clr ,x+                 ; zero the 21-byte work block
        decb
        bne is0
        lda #3
        sta W_LIVES
        lda #112
        sta W_PX
        ldx #W_BRK
        lda #$FF
        ldb #5
is1:    sta ,x+
        decb
        bne is1
        clr ACC
        ; fall through
attach:                         ; ball on the paddle, velocity 0
        ldd #0
        std W_VX
        std W_VY
        lda W_PX
        adda #14
        clrb
        std W_BX
        ldd #$AC00              ; 172 << 8
        std W_BY
        rts

publish:                        ; W_* (big-endian) -> gpf_state (little-endian) + gpf_bricks
        ldd W_STEP
        stb gpf_state
        sta gpf_state+1
        lda W_MODE
        sta gpf_state+2
        lda W_LIVES
        sta gpf_state+3
        ldd W_SCORE
        stb gpf_state+4
        sta gpf_state+5
        lda W_PX
        sta gpf_state+6
        lda W_CLR
        sta gpf_state+7
        ldd W_BX
        stb gpf_state+8
        sta gpf_state+9
        ldd W_BY
        stb gpf_state+10
        sta gpf_state+11
        ldd W_VX
        stb gpf_state+12
        sta gpf_state+13
        ldd W_VY
        stb gpf_state+14
        sta gpf_state+15
        ldx #W_BRK
        ldy #gpf_bricks
        ldb #5
pb0:    lda ,x+
        sta ,y+
        decb
        bne pb0
        rts

; ---------------------------------------------------------------- simulation
sim_step:
        ldd W_STEP
        addd #1
        std W_STEP
        lda W_MODE
        cmpa #MODE_OVER
        bhs simret              ; OVER / WON freeze everything but step
        ; paddle: LEFT only / RIGHT only move 4 px, clamped; both cancel
        lda W_PX
        ldb BTN
        andb #3
        cmpb #1
        bne notleft
        suba #4
        bhs stl
        clra
stl:    sta W_PX
        bra moved
notleft:
        cmpb #2
        bne moved
        adda #4
        cmpa #224
        bls str
        lda #224
str:    sta W_PX
moved:
        lda W_MODE
        bne play
        ; ---- WAIT: re-attach, FIRE launches (ball does not move this step)
        jsr attach
        lda BTN
        anda #4
        beq simret
        ldd #VY_LAUNCH
        std W_VY
        lda BTN
        anda #1
        beq chkr
        ldd #VX_LEFT
        std W_VX
        bra launched
chkr:   lda BTN
        anda #2
        beq launched
        ldd #VX_RIGHT
        std W_VX
launched:
        lda #MODE_PLAY
        sta W_MODE
simret: rts

play:
        ; ---- move x. carry => result >= 0 ; no carry with vx<0 => negative.
        ldd W_BX
        addd W_VX
        bcs xrange
        tst W_VX
        bpl xrange
        ldd #0                  ; x < 0: clamp, vx = |vx|
        std W_BX
        subd W_VX
        std W_VX
        bra xdone
xrange: std W_BX                ; x > 252<<8 ($FC00): clamp, vx = -|vx|
        subd #$FC01
        blo xdone
        ldd #$FC00
        std W_BX
        ldd #0
        subd W_VX
        std W_VX
xdone:
        ; ---- move y, top wall only
        ldd W_BY
        addd W_VY
        std W_BY                ; ST* leaves carry alone
        bcs ydone
        tst W_VY
        bpl ydone
        ldd #0                  ; y < 0: clamp, vy = |vy|
        std W_BY
        subd W_VY
        std W_VY
ydone:
        ; ---- paddle: vy > 0, 172 <= by < 184, x overlap [px-3 .. px+31]
        ldd W_VY
        bmi nopad
        beq nopad
        lda W_BY
        cmpa #172
        blo nopad
        cmpa #184
        bhs nopad
        lda W_BX
        sta T_BX
        ldb W_PX
        stb T_PX
        adda #3                 ; bx+3 >= px  (bx+4 > px)
        cmpa T_PX
        blo nopad
        addb #32                ; bx < px+32 (always true if px+32 = 256)
        bcs xok
        stb T_X2
        lda T_BX
        cmpa T_X2
        bhs nopad
xok:    ldd #$AC00              ; y = 172<<8
        std W_BY
        ldd #0                  ; vy > 0 here, so -|vy| == -vy
        subd W_VY
        std W_VY
        lda T_BX                ; zone = clamp(bx+2-px, 0, 31) >> 3
        adda #2
        suba W_PX
        bhs zpos
        clra
zpos:   cmpa #32
        blo zok
        lda #31
zok:    lsra
        lsra
        lsra
        asla                    ; word index
        ldx #zone_vx
        ldd a,x
        std W_VX
nopad:
        ; ---- bricks: first overlapped, row-major, at most one
        lda W_BY
        sta T_BY
        lda W_BX
        sta T_BX
        clr T_ROW
rowloop:
        ldx #rowthr             ; row overlaps iff 0 <= by-(21+8r) < 11
        ldb T_ROW
        lda T_BY
        suba b,x
        blo nextrow
        cmpa #11
        bhs nextrow
        lda T_BX                ; col = bx>>5; col+1 too if (bx&31) >= 29
        lsra
        lsra
        lsra
        lsra
        lsra
        sta T_COL
        lbsr testbit
        bne hit
        lda T_BX
        anda #31
        cmpa #29
        blo nextrow
        lda T_COL
        inca
        cmpa #8
        bhs nextrow
        sta T_COL
        lbsr testbit
        bne hit
nextrow:
        inc T_ROW
        lda T_ROW
        cmpa #5
        bne rowloop
        bra nobrick
hit:
        lda T_MASK              ; clear the bit (known set); X = &W_BRK[row]
        eora ,x
        sta ,x
        ldx #rowscore           ; score += 50 - 10*row
        ldb T_ROW
        ldb b,x
        clra
        addd W_SCORE
        std W_SCORE
        inc W_CLR
        ldd #0                  ; vy flips (plain negation)
        subd W_VY
        std W_VY
        lda W_CLR               ; every 10th brick: |vy| += $40, max $300
mod10:  suba #10
        beq speed
        bhi mod10
        bra nobrick
speed:
        ldd W_VY
        sta T_SIGN
        bpl pos
        pshs d
        ldd #0
        subd ,s++               ; D = |vy|
pos:    addd #$40
        cmpd #$301
        blo spdok
        ldd #$300
spdok:  tst T_SIGN
        bpl spdst
        pshs d
        ldd #0
        subd ,s++
spdst:  std W_VY
nobrick:
        ; ---- win (checked before miss), then miss
        lda W_BRK
        ora W_BRK+1
        ora W_BRK+2
        ora W_BRK+3
        ora W_BRK+4
        bne notwon
        lda #MODE_WON
        sta W_MODE
        rts
notwon: lda W_BY
        cmpa #193               ; (y>>8) > 192
        lblo simret
        dec W_LIVES
        bne towait
        lda #MODE_OVER
        sta W_MODE
        ldd #0
        std W_VX
        std W_VY
        rts
towait: clr W_MODE              ; MODE_WAIT
        jmp attach

; in: T_ROW, T_COL. out: NZ if the brick is present; X = &W_BRK[row],
; T_MASK = its bit.
testbit:
        ldx #bitmask
        lda T_COL
        lda a,x
        sta T_MASK
        ldx #W_BRK
        ldb T_ROW
        abx
        lda T_MASK
        anda ,x
        rts

zone_vx:    fdb $FE80,$FF40,$00C0,$0180  ; -0x180 -0xC0 +0xC0 +0x180
rowthr:     fcb 21,29,37,45,53           ; 21 + 8*row
rowscore:   fcb 50,40,30,20,10
bitmask:    fcb 1,2,4,8,16,32,64,128

; ---------------------------------------------------------------- video
; RENDER-ONLY: reads the working copy (W_*) and writes only the screen and the
; R_*/T_* render variables. It never writes gpf_state or a sim variable.
; Two colours (black / buff, CSS=1). Bricks are drawn once and cleared when they die;
; the ball (4x4) and paddle (32x8) are XOR-drawn. Order each step, because XOR
; draws commute but plain writes do not: (1) erase ball, (2) bricks/HUD/message,
; (3) paddle XOR, (4) draw ball.
init_video:
        sta $FFC0               ; SAM V = 110 (mode 6, 6144 B). STA not LDA: strobe wants a write cycle
        sta $FFC3
        sta $FFC5
        sta $FFC6               ; SAM F = 16 -> $2000 (F4 set, rest clear)
        sta $FFC8
        sta $FFCA
        sta $FFCC
        sta $FFCF
        sta $FFD2
        sta $FFD0
        lda #$34                ; PIA0 CB1: data register selected, falling edge, no IRQ
        sta $FF03
        lda $FF22               ; PIA1 B: A/G=1, GM=111 (RG6), CSS=1
        anda #$07
        ora #$F8
        sta $FF22
        ldx #SCR
        ldd #0
cls:    std ,x++
        cmpx #SCR+6144
        bne cls
        rts

init_render:
        ldx #R_BRK
        ldb #5
ir0:    clr ,x+
        decb
        bne ir0
        ldd #$FFFF
        std R_SCORE
        sta R_LIVES
        sta R_MODE
        sta R_PX
        sta R_BY
        rts

render:
        lda R_BY                ; (1) erase the ball
        cmpa #$FF
        beq r1
        sta T_BY
        lda R_BX
        sta T_BX
        jsr ball_xor
r1:     jsr render_bricks       ; (2)
        jsr render_hud
        lda R_PX                ; (3) paddle
        cmpa W_PX
        beq r3
        cmpa #$FF
        beq r2
        jsr paddle_xor          ; erase old
r2:     lda W_PX
        sta R_PX
        jsr paddle_xor          ; draw new
r3:     lda W_BY                ; (4) ball, hidden once it is below the playfield
        cmpa #189
        bhs hide
        sta T_BY
        sta R_BY
        lda W_BX
        sta T_BX
        sta R_BX
        jmp ball_xor
hide:   lda #$FF
        sta R_BY
        rts

; bricks: draw/erase only the cells whose bit differs from what is on screen
render_bricks:
        clr T_ROW
rb0:    ldb T_ROW
        ldx #W_BRK
        lda b,x
        sta R_NEW
        ldx #R_BRK
        eora b,x
        sta R_DIFF
        beq rbnext
        lda R_NEW
        sta b,x
        clr R_COL
        lda #1
        sta R_BIT
rb1:    lda R_DIFF
        anda R_BIT
        beq rbcn
        lda T_ROW               ; X = SCR + 24*32 + row*256 + col*4 = $2300 + ...
        adda #$23
        ldb R_COL
        aslb
        aslb
        tfr d,x
        lda R_NEW
        anda R_BIT
        bne rbdraw
        bsr brick_erase
        bra rbcn
rbdraw: bsr brick_draw
rbcn:   asl R_BIT
        inc R_COL
        lda R_COL
        cmpa #8
        bne rb1
rbnext: inc T_ROW
        lda T_ROW
        cmpa #5
        bne rb0
        rts

brick_draw:                     ; 32x8 at X: 7 lines solid with a 1 px gap right, 1 line gap below
        lda #7
        sta T_N
bd1:    ldd #$FFFF
        std ,x
        ldd #$FFFE
        std 2,x
        leax 32,x
        dec T_N
        bne bd1
        ldd #0
        std ,x
        std 2,x
        rts

brick_erase:
        lda #8
        sta T_N
be1:    ldd #0
        std ,x
        std 2,x
        leax 32,x
        dec T_N
        bne be1
        rts

; paddle XOR, A = px (always a multiple of 4): 8 lines, 5 bytes wide
paddle_xor:
        sta T_ARG
        lsra
        lsra
        lsra                    ; byte column
        tfr a,b
        lda #$36                ; $3600 = SCR + 176*32
        tfr d,x
        lda T_ARG
        anda #4
        bne pshift
        ldd #$FFFF
        std R_PB
        std R_PB+2
        clr R_PB+4
        bra pgo
pshift: lda #$0F
        sta R_PB
        lda #$FF
        sta R_PB+1
        sta R_PB+2
        sta R_PB+3
        lda #$F0
        sta R_PB+4
pgo:    lda #8
        sta T_N
pl:     lda ,x
        eora R_PB
        sta ,x
        lda 1,x
        eora R_PB+1
        sta 1,x
        lda 2,x
        eora R_PB+2
        sta 2,x
        lda 3,x
        eora R_PB+3
        sta 3,x
        lda 4,x
        eora R_PB+4
        sta 4,x
        leax 32,x
        dec T_N
        bne pl
        rts

; ball XOR at (T_BX, T_BY): 4 lines of a rounded 4x4, shifted by bx&7 across 2 bytes.
; pattern * (256 >> s) leaves the shifted pattern in A:B (MUL), s = 0 handled apart.
ball_xor:
        lda T_BY
        ldb #32
        mul
        addd #SCR
        tfr d,x
        lda T_BX
        lsra
        lsra
        lsra
        leax a,x
        lda T_BX
        anda #7
        ldy #shmul
        ldb a,y
        stb T_MUL
        lda #4
        sta T_N
        ldy #ball_pat
bx1:    lda ,y+
        ldb T_MUL
        beq bx2
        mul
bx2:    sta T_M0
        stb T_M1
        lda ,x
        eora T_M0
        sta ,x
        lda 1,x
        eora T_M1
        sta 1,x
        leax 32,x
        dec T_N
        bne bx1
        rts

shmul:      fcb 0,128,64,32,16,8,4,2
ball_pat:   fcb $60,$F0,$F0,$60

; HUD: lives as pips (y 8..12, bytes 1,3,5) and a 4-digit score (y 8..12, bytes 28-29);
; mode message bar (y 96..103) while OVER / WON. Written only when the value changed.
render_hud:
        lda W_LIVES
        cmpa R_LIVES
        beq rh1
        sta R_LIVES
        clr T_COL
rh0:    ldb T_COL               ; pip i at $2101 + 2i
        aslb
        ldx #SCR+$101
        abx
        lda T_COL
        inca
        cmpa W_LIVES            ; present iff i+1 <= lives
        bls pipon
        clra
        bra pipw
pipon:  lda #$7E
pipw:   sta ,x
        sta 32,x
        sta 64,x
        sta 96,x
        sta 128,x
        inc T_COL
        lda T_COL
        cmpa #3
        bne rh0
rh1:    ldd W_SCORE
        cmpd R_SCORE
        beq rh2
        std R_SCORE
        bsr draw_score
rh2:    lda W_MODE
        cmpa R_MODE
        beq rh3
        sta R_MODE
        bra draw_msg
rh3:    rts

draw_msg:                       ; 8 lines x 16 bytes at $2C08: WON solid, OVER dither, else clear
        ldx #SCR+$C08
        lda #8
        sta T_N
dm0:    ldb #16
        lda W_MODE
        cmpa #MODE_WON
        bne dm1
        lda #$FF
        bra dm3
dm1:    cmpa #MODE_OVER
        bne dm2
        lda T_N
        anda #1
        beq dm4
        lda #$55
        bra dm3
dm4:    lda #$AA
        bra dm3
dm2:    clra
dm3:    sta ,x+
        decb
        bne dm3
        leax 16,x
        dec T_N
        bne dm0
        rts

; score < 10000 -> 4 decimal digits in R_DIG, drawn as 3x5 glyphs, two per byte
draw_score:
        ldd W_SCORE
        ldx #pow10
        ldy #R_DIG
ds0:    clr ,y
ds1:    subd ,x
        blo ds2
        inc ,y
        bra ds1
ds2:    addd ,x
        leay 1,y
        leax 2,x
        cmpx #pow10+8
        bne ds0
        ldu #SCR+$11C
        clr T_L
ds3:    lda R_DIG
        bsr glyph
        ldb #5
ds4:    asla
        decb
        bne ds4                 ; <<5 (bits 7-5)
        sta T_P
        lda R_DIG+1
        bsr glyph
        asla                    ; <<1 (bits 3-1)
        ora T_P
        sta ,u
        lda R_DIG+2
        bsr glyph
        ldb #5
ds5:    asla
        decb
        bne ds5
        sta T_P
        lda R_DIG+3
        bsr glyph
        asla
        ora T_P
        sta 1,u
        leau 32,u
        inc T_L
        lda T_L
        cmpa #5
        bne ds3
        rts

glyph:                          ; A = digit, T_L = line -> A = 3-bit row
        ldb #5
        mul
        addb T_L
        ldx #font
        lda b,x
        rts

pow10:      fdb 1000,100,10,1
font:       fcb 7,5,5,5,7          ; 0
            fcb 2,6,2,2,7          ; 1
            fcb 7,1,7,4,7          ; 2
            fcb 7,1,7,1,7          ; 3
            fcb 5,5,7,1,1          ; 4
            fcb 7,4,7,1,7          ; 5
            fcb 7,4,7,5,7          ; 6
            fcb 7,1,1,1,1          ; 7
            fcb 7,5,7,5,7          ; 8
            fcb 7,5,7,1,7          ; 9

; the DECB loader transfers control here
        end start
