; Brickfall -- C64 (PAL) build. acme.
;
; Simulation is bit-exact with games/brickfall/recipe/model (see recipe README,
; "Resolved ambiguities") and FROZEN. Presentation (custom charset bricks, side
; panels, sprites, status/messages, SID effects) is additive: it only reads the
; sim's state, never writes gpf_state or the zero-page working copy.
;
; Harness contract (recipe README "State contract" / "Input contract"):
;   gpf_state  16 bytes, updated at the END of every simulation step
;   gpf_bricks  5 bytes, directly after gpf_state
;   gpf_input_ret  the RTS of read_input; A = buttons (1 LEFT, 2 RIGHT, 4 FIRE)
; The shipped build has no test-only code path: the harness overwrites A at
; gpf_input_ret from the outside.

!cpu 6502


; ---------------------------------------------------------------- constants
SCREEN      = $0400
COLOR       = $d800

; Published state (plain RAM at $C000, not part of the PRG image).
gpf_state   = $c000
gpf_bricks  = $c010

; Working copy of the state, same layout, in zero page. The sim mutates this
; and publish() copies it to gpf_state/gpf_bricks at the end of the step.
W_STEP      = $20       ; 2
W_MODE      = $22
W_LIVES     = $23
W_SCORE     = $24       ; 2
W_PX        = $26
W_CLR       = $27
W_BX        = $28       ; 2  8.8
W_BY        = $2a       ; 2  8.8
W_VX        = $2c       ; 2  signed 8.8
W_VY        = $2e       ; 2  signed 8.8
W_BRK       = $30       ; 5

BTN         = $38
T0          = $39
T_BX        = $3a
T_BY        = $3b
T_SIGN      = $3c
; Render/sound temporaries live OUTSIDE the sim working copy ($20-$34) and
; outside the sim's own temps ($38-$3c): rendering and sound only READ the sim.
R_ROW       = $f0
R_COL       = $f1
R_MASK      = $f2
R_CLR       = $f3
Z_T         = $f4
Z_V         = $f5
Z_L         = $f6
Z_H         = $f7
Z_C         = $f8
MP          = $f9       ; message pointer (2)
Z_T2        = $ef
SP          = $fb       ; screen pointer (2)
CP          = $fd       ; colour pointer (2)

; Render/sound state in plain RAM outside the PRG (never read by the sim).
P_MODE      = $c100     ; previous published state, for sound event detection
P_LIVES     = $c101
P_SCORE     = $c102
P_CLR       = $c103
P_VXS       = $c104
P_VYS       = $c105
V_IDX       = $c108     ; per voice: offset into seqdata, $ff = idle (2)
V_TIM       = $c10a     ; per voice: frames left in the note (2)
V_WAVE      = $c10c     ; per voice: waveform without gate (2)
RP_BRK      = $c120     ; brick mask as last drawn (5)
RP_MODE     = $c125     ; mode as last drawn

CH_BL       = 64        ; custom characters (charset RAM at $2000)
CH_BM       = 65
CH_BR       = 66
CH_PANEL    = 67
CH_WALLL    = 68
CH_WALLR    = 69
CH_HEART    = 70

MODE_WAIT   = 0
MODE_PLAY   = 1
MODE_OVER   = 2
MODE_WON    = 3

VY_LAUNCH   = $fe80     ; -0x0180
VX_LEFT     = $ff80     ; -0x0080
VX_RIGHT    = $0080

!macro neg16 .a {
    sec
    lda #0
    sbc .a
    sta .a
    lda #0
    sbc .a+1
    sta .a+1
}

; ---------------------------------------------------------------- BASIC stub
* = $0801
    !word +, 10
    !byte $9e
    !text "2064"
    !byte 0
+   !word 0

* = $0810
start:
    sei
    cld
    ldx #$ff
    txs
    jsr init_video
    jsr init_state
    jsr publish
    jsr snd_init
    jsr render
mainloop:
    jsr wait_frame
    jsr read_input
    sta BTN
    jsr sim_step
    jsr publish
    jsr render
    jsr sound
    jmp mainloop

; ---------------------------------------------------------------- frame sync
; One simulation step per 50 Hz (PAL) frame: run once when the raster reaches
; line 251. First leave line 251 so a fast step cannot run twice in a frame.
wait_frame:
-   lda $d012
    cmp #$fb
    beq -
-   lda $d012
    cmp #$fb
    bne -
    rts

; ---------------------------------------------------------------- input
; Joystick port 2 (CIA1 port A) + keyboard Z / X / SPACE.
; Returns buttons in A: 1 LEFT, 2 RIGHT, 4 FIRE.
read_input:
    lda #0
    sta $dc02               ; DDRA = input: read joystick 2
    sta $dc03               ; DDRB = input
    lda $dc00
    eor #$ff                ; 1 = pressed
    sta T0
    ldy #0
    lda T0
    and #$04                ; joy left
    beq +
    iny
+   lda T0
    and #$08                ; joy right
    beq +
    tya
    ora #$02
    tay
+   lda T0
    and #$10                ; joy fire
    beq +
    tya
    ora #$04
    tay
+   sty T0
    ; keyboard: drive one column at a time, read rows
    lda #$ff
    sta $dc02               ; DDRA = output
    lda #$fd                ; column 1: Z = row 4
    sta $dc00
    nop
    nop
    lda $dc01
    and #$10
    bne +
    lda T0
    ora #$01
    sta T0
+   lda #$fb                ; column 2: X = row 7
    sta $dc00
    nop
    nop
    lda $dc01
    and #$80
    bne +
    lda T0
    ora #$02
    sta T0
+   lda #$7f                ; column 7: SPACE = row 4
    sta $dc00
    nop
    nop
    lda $dc01
    and #$10
    bne +
    lda T0
    ora #$04
    sta T0
+   lda #0
    sta $dc02               ; back to input so the joystick reads cleanly
    lda T0
gpf_input_ret:
    rts

; ---------------------------------------------------------------- state
init_state:
    lda #0
    sta W_STEP
    sta W_STEP+1
    sta W_MODE
    sta W_SCORE
    sta W_SCORE+1
    sta W_CLR
    lda #3
    sta W_LIVES
    lda #112
    sta W_PX
    lda #$ff
    ldx #4
-   sta W_BRK,x
    dex
    bpl -
    ; fall through
attach:                     ; ball on the paddle, velocity 0
    lda #0
    sta W_BX
    sta W_BY
    sta W_VX
    sta W_VX+1
    sta W_VY
    sta W_VY+1
    lda W_PX
    clc
    adc #14
    sta W_BX+1
    lda #172
    sta W_BY+1
    rts

publish:                    ; working copy -> gpf_state + gpf_bricks (21 bytes)
    ldx #20
-   lda W_STEP,x
    sta gpf_state,x
    dex
    bpl -
    rts

; ---------------------------------------------------------------- simulation
sim_step:
    inc W_STEP
    bne +
    inc W_STEP+1
+   lda W_MODE
    cmp #MODE_OVER
    bcc @active
    rts                     ; OVER / WON freeze everything but step
@active:
    ; paddle: LEFT only / RIGHT only move 4 px, clamped; both cancel
    lda BTN
    and #3
    cmp #1
    bne @notleft
    lda W_PX
    sec
    sbc #4
    bcs +
    lda #0
+   sta W_PX
    jmp @moved
@notleft:
    cmp #2
    bne @moved
    lda W_PX
    clc
    adc #4
    cmp #225
    bcc +
    lda #224
+   sta W_PX
@moved:
    lda W_MODE
    bne @play
    ; ---- WAIT: re-attach, FIRE launches (ball does not move this step)
    jsr attach
    lda BTN
    and #4
    beq @waitdone
    lda #<VY_LAUNCH
    sta W_VY
    lda #>VY_LAUNCH
    sta W_VY+1
    lda BTN
    and #1
    beq +
    lda #<VX_LEFT
    sta W_VX
    lda #>VX_LEFT
    sta W_VX+1
    jmp @launched
+   lda BTN
    and #2
    beq @launched
    lda #<VX_RIGHT
    sta W_VX
    lda #>VX_RIGHT
    sta W_VX+1
@launched:
    lda #MODE_PLAY
    sta W_MODE
@waitdone:
    rts

@play:
    ; ---- move x. Unsigned 16-bit add of (ball_x + vx): carry set => result >= 0
    ; (or vx<0 wrapped), carry clear with vx<0 => negative.
    clc
    lda W_BX
    adc W_VX
    sta W_BX
    lda W_BX+1
    adc W_VX+1
    sta W_BX+1
    bcs @xrange
    lda W_VX+1
    bpl @xrange
    lda #0                  ; x < 0: clamp, vx = |vx|
    sta W_BX
    sta W_BX+1
    +neg16 W_VX
    jmp @xdone
@xrange:                    ; x > 252<<8 ($FC00): clamp, vx = -|vx|
    lda W_BX+1
    cmp #$fc
    bcc @xdone
    bne @xhigh
    lda W_BX
    beq @xdone
@xhigh:
    lda #0
    sta W_BX
    lda #$fc
    sta W_BX+1
    +neg16 W_VX
@xdone:
    ; ---- move y, top wall only
    clc
    lda W_BY
    adc W_VY
    sta W_BY
    lda W_BY+1
    adc W_VY+1
    sta W_BY+1
    bcs @ydone
    lda W_VY+1
    bpl @ydone
    lda #0
    sta W_BY
    sta W_BY+1
    +neg16 W_VY
@ydone:
    ; ---- paddle: vy > 0, 172 <= by < 184, x overlap [px-3 .. px+31]
    lda W_VY+1
    bmi @nopad
    ora W_VY
    beq @nopad
    lda W_BY+1
    cmp #172
    bcc @nopad
    cmp #184
    bcs @nopad
    lda W_PX
    cmp #4
    bcc @c1ok
    sec
    sbc #3
    sta T0
    lda W_BX+1
    cmp T0
    bcc @nopad              ; bx < px-3
@c1ok:
    lda W_PX
    cmp #224
    bcs @c2ok
    clc
    adc #32
    sta T0
    lda W_BX+1
    cmp T0
    bcs @nopad              ; bx >= px+32
@c2ok:
    lda #0                  ; y = 172<<8
    sta W_BY
    lda #172
    sta W_BY+1
    +neg16 W_VY             ; vy > 0 here, so -|vy| == -vy
    lda W_BX+1              ; zone = clamp(bx+2-px, 0, 31) >> 3
    clc
    adc #2
    sec
    sbc W_PX
    bcs +
    lda #0
+   cmp #32
    bcc +
    lda #31
+   lsr
    lsr
    lsr
    asl
    tax
    lda zone_vx,x
    sta W_VX
    lda zone_vx+1,x
    sta W_VX+1
@nopad:
    ; ---- bricks: first overlapped, row-major, at most one
    lda W_BY+1
    sta T_BY
    lda W_BX+1
    sta T_BX
    ldx #0
@rowloop:
    lda T_BY                ; row overlaps iff 0 <= by-(21+8r) < 11
    sec
    sbc rowthr,x
    bcc @nextrow
    cmp #11
    bcs @nextrow
    lda T_BX                ; col A = bx>>5; col A+1 too if (bx&31) >= 29
    lsr
    lsr
    lsr
    lsr
    lsr
    tay
    lda W_BRK,x
    and bitmask,y
    bne @hit
    lda T_BX
    and #31
    cmp #29
    bcc @nextrow
    iny
    cpy #8
    bcs @nextrow
    lda W_BRK,x
    and bitmask,y
    bne @hit
@nextrow:
    inx
    cpx #5
    bne @rowloop
    jmp @nobrick
@hit:
    lda W_BRK,x             ; clear the bit (known set)
    eor bitmask,y
    sta W_BRK,x
    clc                     ; score += 50 - 10*row
    lda W_SCORE
    adc rowscore,x
    sta W_SCORE
    bcc +
    inc W_SCORE+1
+   inc W_CLR
    +neg16 W_VY             ; vy flips (plain negation)
    lda W_CLR               ; every 10th brick: |vy| += $40, max $300
@mod10:
    beq @speed
    sec
    sbc #10
    bcs @mod10
    jmp @nobrick
@speed:
    lda W_VY+1
    sta T_SIGN
    bpl +
    +neg16 W_VY
+   clc
    lda W_VY
    adc #$40
    sta W_VY
    bcc +
    inc W_VY+1
+   lda W_VY+1
    cmp #3
    bcc @spdok
    bne @spdclamp
    lda W_VY
    beq @spdok
@spdclamp:
    lda #0
    sta W_VY
    lda #3
    sta W_VY+1
@spdok:
    lda T_SIGN
    bpl @nobrick
    +neg16 W_VY
@nobrick:
    ; ---- win (checked before miss), then miss
    lda W_BRK
    ora W_BRK+1
    ora W_BRK+2
    ora W_BRK+3
    ora W_BRK+4
    bne @notwon
    lda #MODE_WON
    sta W_MODE
    rts
@notwon:
    lda W_BY+1
    cmp #193                ; (y>>8) > 192
    bcc @done
    dec W_LIVES
    bne @towait
    lda #MODE_OVER
    sta W_MODE
    lda #0
    sta W_VX
    sta W_VX+1
    sta W_VY
    sta W_VY+1
    rts
@towait:
    lda #MODE_WAIT
    sta W_MODE
    jsr attach
@done:
    rts

zone_vx:    !word $fe80, $ff40, $00c0, $0180    ; -0x180 -0xC0 +0xC0 +0x180
rowthr:     !byte 21, 29, 37, 45, 53            ; 21 + 8*row
rowscore:   !byte 50, 40, 30, 20, 10
bitmask:    !byte 1, 2, 4, 8, 16, 32, 64, 128

; ================================================================ presentation
; Everything below only READS the sim (W_* / gpf_state) and never writes to it.
; Layout (40x25 text screen, VIC bank 0, charset RAM at $2000):
;   cols 0-2 / 37-39 brick-wall side panels, cols 3 / 36 wall bars: they frame the
;   256x192 logical playfield, which is char cols 4-35, rows 0-23 (sprite X = 56+x,
;   Y = 50+y). Row 24 = status line (score, lives, mode). Messages (title / game
;   over / win) are drawn inside the empty middle of the field at rows 10, 12, 14.
; The vblank budget (lines 251..311 + 0..50, ~7000 cycles) is kept by redrawing
; the bricks / messages only when they change; sprites are written first.

STAT        = SCREEN+24*40

init_video:
    lda #$06
    sta $d020               ; border: blue
    lda #0
    sta $d021
    lda #$1b                ; 25 rows, display on, yscroll 3
    sta $d011
    lda #$c8                ; 40 cols, hires text
    sta $d016
    lda #$18                ; screen $0400, charset RAM $2000
    sta $d018
    lda $dd00               ; VIC bank 0
    ora #3
    sta $dd00
    ; charset: copy screen codes 0-63 (letters, digits, punctuation) from the
    ; character ROM at runtime (nothing of it is shipped); 64.. are ours at $2200.
    lda $01
    sta Z_T
    and #$fb                ; CHAREN = 0: character ROM visible at $d000
    sta $01
    ldx #0
-   lda $d000,x
    sta $2000,x
    lda $d100,x
    sta $2100,x
    inx
    bne -
    lda Z_T
    sta $01
    ; clear screen + colour
    ldx #0
-   lda #$20
    sta SCREEN,x
    sta SCREEN+$100,x
    sta SCREEN+$200,x
    sta SCREEN+$2e8,x
    lda #1
    sta COLOR,x
    sta COLOR+$100,x
    sta COLOR+$200,x
    sta COLOR+$2e8,x
    inx
    bne -
    ; frame: rows 0-23 from the row templates
    lda #<SCREEN
    sta SP
    lda #>SCREEN
    sta SP+1
    lda #<COLOR
    sta CP
    lda #>COLOR
    sta CP+1
    lda #24
    sta R_ROW
@frow:
    ldy #39
-   lda frame_ch,y
    sta (SP),y
    lda frame_col,y
    sta (CP),y
    dey
    bpl -
    clc
    lda SP
    adc #40
    sta SP
    bcc +
    inc SP+1
+   clc
    lda CP
    adc #40
    sta CP
    bcc +
    inc CP+1
+   dec R_ROW
    bne @frow
    ; sprites: 0 = ball, 1 = paddle highlight (in front), 2 = paddle body (same place)
    lda #sprite_ball/64
    sta SCREEN+$3f8
    lda #sprite_high/64
    sta SCREEN+$3f9
    lda #sprite_body/64
    sta SCREEN+$3fa
    lda #7
    sta $d015
    lda #6
    sta $d01d               ; expand sprites 1 and 2 horizontally (16 -> 32 px)
    lda #0
    sta $d017
    sta $d01c               ; hires sprites
    lda #1
    sta $d027               ; ball white
    lda #1
    sta $d028               ; paddle highlight white
    lda #3
    sta $d029               ; paddle body cyan
    ; static status labels
    ldx #4
-   lda txt_score,x
    sta STAT+1,x
    lda txt_lives,x
    sta STAT+15,x
    lda #15
    sta COLOR+24*40+1,x
    sta COLOR+24*40+15,x
    dex
    bpl -
    lda #10                 ; hearts: light red
    sta COLOR+24*40+21
    sta COLOR+24*40+22
    sta COLOR+24*40+23
    ; force a first full redraw
    lda #0
    ldx #4
-   sta RP_BRK,x
    dex
    bpl -
    lda #$ff
    sta RP_MODE
    rts

render:
    jsr r_sprites           ; first, inside vblank: no tearing
    jsr r_bricks
    jsr r_status
    jmp r_mode

r_sprites:
    lda W_BX+1              ; ball is a 6x6 disc around the 4x4 box: -1 px
    clc
    adc #55
    sta $d000
    lda #0
    rol
    sta Z_T                 ; X msb of the ball
    lda W_BY+1
    clc
    adc #49
    sta $d001
    lda W_PX
    clc
    adc #56
    sta $d002
    sta $d004
    lda #0
    rol                     ; X msb of the paddle
    asl
    sta Z_C
    asl
    ora Z_C                 ; 6 * msb: sprites 1 and 2
    ora Z_T
    sta $d010
    lda #226                ; 50 + 176
    sta $d003
    sta $d005
    lda #7                  ; after the last miss the ball sits below the field: hide it
    ldx W_MODE
    cpx #MODE_OVER
    bne +
    lda #6
+   sta $d015
    rts

; Bricks: 4 chars each (left cap, 2 mid, right cap), one colour per row, only
; when the mask changed since the last draw.
r_bricks:
    ldx #4
-   lda W_BRK,x
    cmp RP_BRK,x
    bne @redraw
    dex
    bpl -
    rts
@redraw:
    ldx #4
-   lda W_BRK,x
    sta RP_BRK,x
    dex
    bpl -
    lda #<(SCREEN+3*40+4)
    sta SP
    lda #>(SCREEN+3*40+4)
    sta SP+1
    lda #<(COLOR+3*40+4)
    sta CP
    lda #>(COLOR+3*40+4)
    sta CP+1
    lda #0
    sta R_ROW
@row:
    ldx R_ROW
    lda W_BRK,x
    sta R_MASK
    lda rowcol,x
    ldy #31
-   sta (CP),y
    dey
    bpl -
    ldy #0
    ldx #8
@col:
    lsr R_MASK
    bcc @empty
    lda #CH_BL
    sta (SP),y
    iny
    lda #CH_BM
    sta (SP),y
    iny
    sta (SP),y
    iny
    lda #CH_BR
    sta (SP),y
    iny
    jmp @next
@empty:
    lda #$20
    sta (SP),y
    iny
    sta (SP),y
    iny
    sta (SP),y
    iny
    sta (SP),y
    iny
@next:
    dex
    bne @col
    clc
    lda SP
    adc #40
    sta SP
    bcc +
    inc SP+1
+   clc
    lda CP
    adc #40
    sta CP
    bcc +
    inc CP+1
+   inc R_ROW
    lda R_ROW
    cmp #5
    bne @row
    rts

; Score (5 digits) and lives (hearts), every frame (cheap).
r_status:
    lda W_SCORE
    sta Z_L
    lda W_SCORE+1
    sta Z_H
    ldx #0
@dg:
    ldy #0
@sub:
    lda Z_L
    sec
    sbc dec_lo,x
    sta Z_T2
    lda Z_H
    sbc dec_hi,x
    bcc @done
    sta Z_H
    lda Z_T2
    sta Z_L
    iny
    jmp @sub
@done:
    tya
    ora #$30
    sta STAT+7,x
    inx
    cpx #4
    bne @dg
    lda Z_L
    ora #$30
    sta STAT+11
    ldx #0
@h:
    lda #$20
    cpx W_LIVES
    bcs +
    lda #CH_HEART
+   sta STAT+21,x
    inx
    cpx #3
    bne @h
    rts

!macro copyline .scr, .col, .len {
    ldy #.len-1
-   lda (MP),y
    sta .scr,y
    lda R_CLR
    sta .col,y
    dey
    bpl -
    clc
    lda MP
    adc #.len
    sta MP
    bcc +
    inc MP+1
+
}

; Messages + mode text, only when the mode changed.
r_mode:
    lda W_MODE
    cmp RP_MODE
    bne +
    rts
+   sta RP_MODE
    tax
    lda msg_lo,x
    sta MP
    lda msg_hi,x
    sta MP+1
    lda mcol,x
    sta R_CLR
    +copyline SCREEN+10*40+4, COLOR+10*40+4, 32
    +copyline SCREEN+12*40+4, COLOR+12*40+4, 32
    +copyline SCREEN+14*40+4, COLOR+14*40+4, 32
    +copyline STAT+27, COLOR+24*40+27, 12
    lda W_MODE
    bne @done
    ldx #0                  ; title: letters cycle through the brick-row colours
    ldy #0
-   lda rowcol,y
    sta COLOR+10*40+4,x
    iny
    cpy #5
    bne +
    ldy #0
+   inx
    cpx #32
    bne -
@done:
    rts

; ---------------------------------------------------------------- sound
; SID effects, driven from the vblank loop (one O(1) pass per frame, never
; blocking). Events are inferred by comparing the PUBLISHED state with the previous
; step's; nothing here touches the sim. Voice 1 = ball effects, voice 2 = jingles.
; A sequence is: wave, AD, SR, then (freq lo, freq hi, frames)* ended by frames=0.
; A note holds its gate for frames-1 frames, then 1 frame of gate-off (retrigger).
S_PADDLE    = s_paddle-seqdata
S_WALL      = s_wall-seqdata
S_LAUNCH    = s_launch-seqdata
S_MISS      = s_miss-seqdata
S_OVER      = s_over-seqdata
S_WIN       = s_win-seqdata

sound:
    jsr snd_tick
    jsr snd_events
    ; fall through
snd_save:
    lda gpf_state+2
    sta P_MODE
    lda gpf_state+3
    sta P_LIVES
    lda gpf_state+4
    sta P_SCORE
    lda gpf_state+7
    sta P_CLR
    lda gpf_state+$d
    ldx gpf_state+$c
    jsr signcls
    sta P_VXS
    lda gpf_state+$f
    ldx gpf_state+$e
    jsr signcls
    sta P_VYS
    rts

signcls:                    ; A = hi, X = lo  ->  A = 0 zero, 1 positive, 2 negative
    cmp #$80                ; (not bmi: the caller's last load was the LO byte)
    bcs @neg
    stx Z_T
    ora Z_T
    beq @z
    lda #1
@z: rts
@neg:
    lda #2
    rts

snd_init:
    lda #0
    ldx #$18
-   sta $d400,x
    dex
    bpl -
    lda #$0f
    sta $d418               ; volume
    lda #$08
    sta $d403               ; pulse width 50 %, voices 1 and 2
    sta $d40a
    lda #$ff
    sta V_IDX
    sta V_IDX+1
    lda #0
    sta V_TIM
    sta V_TIM+1
    jmp snd_save            ; previous := current, so step 0 raises no event

snd_events:
    lda P_MODE
    cmp #MODE_PLAY
    beq @play
    jmp @notplay
@play:
    lda gpf_state+$d        ; vx sign flipped between non-zero signs: wall
    ldx gpf_state+$c
    jsr signcls
    sta Z_C
    lda P_VXS
    beq @novx
    cmp Z_C
    beq @novx
    ldy Z_C
    beq @novx
    lda #S_WALL
    jsr snd_v0
@novx:
    lda gpf_state+$f
    ldx gpf_state+$e
    jsr signcls
    sta Z_C
    lda P_VYS
    cmp #2
    bne @notup
    lda Z_C                 ; up -> down: top wall (a brick overrides below)
    cmp #1
    bne @vydone
    lda #S_WALL
    jsr snd_v0
    jmp @vydone
@notup:
    cmp #1
    bne @vydone
    lda Z_C                 ; down -> up: paddle
    cmp #2
    bne @vydone
    lda #S_PADDLE
    jsr snd_v0
@vydone:
    lda gpf_state+7         ; cleared count changed: brick, pitch by row score
    cmp P_CLR
    beq @after
    lda gpf_state+4
    sec
    sbc P_SCORE             ; 50 - 10*row
    ldx #0
-   cmp #10
    bcc +
    sbc #10
    inx
    bne -
+   lda brick_tab-1,x       ; tens 1..5
    jsr snd_v0
    jmp @after
@notplay:
    cmp #MODE_WAIT
    bne @after
    lda gpf_state+2
    cmp #MODE_PLAY
    bne @after
    lda #S_LAUNCH
    jsr snd_v0
@after:
    lda gpf_state+2
    cmp #MODE_WON
    bne @notwon
    lda P_MODE
    cmp #MODE_WON
    beq @notwon
    lda #S_WIN
    jsr snd_v1
@notwon:
    lda gpf_state+3
    cmp P_LIVES
    bcs @nolife             ; no life lost
    lda gpf_state+2
    cmp #MODE_OVER
    bne @miss
    lda #S_OVER
    jmp snd_v1
@miss:
    lda #S_MISS
    jmp snd_v1
@nolife:
    rts

snd_v0:
    ldx #0
    ldy #0
    jmp snd_start
snd_v1:
    ldx #1
    ldy #7
    ; fall through
snd_start:                  ; A = sequence offset, X = voice index, Y = SID reg offset
    sta Z_T
    stx Z_V
    ldx Z_T
    lda seqdata,x
    pha
    lda seqdata+1,x
    sta $d405,y             ; AD
    lda seqdata+2,x
    sta $d406,y             ; SR
    lda #0
    sta $d404,y             ; gate off now; first note starts next frame (retrigger)
    ldx Z_V
    pla
    sta V_WAVE,x
    lda Z_T
    clc
    adc #3
    sta V_IDX,x
    lda #1
    sta V_TIM,x
    rts

snd_tick:
    ldx #1
@v: lda V_IDX,x
    cmp #$ff
    beq @next
    dec V_TIM,x
    beq @note
    lda V_TIM,x
    cmp #1
    bne @next
    lda voffs,x             ; last frame of the note: gate off
    tay
    lda V_WAVE,x
    sta $d404,y
    jmp @next
@note:
    ldy V_IDX,x
    lda seqdata+2,y
    beq @end
    sta V_TIM,x
    lda seqdata,y
    sta Z_L
    lda seqdata+1,y
    sta Z_H
    tya
    clc
    adc #3
    sta V_IDX,x
    lda voffs,x
    tay
    lda Z_L
    sta $d400,y
    lda Z_H
    sta $d401,y
    lda V_WAVE,x
    ora #1
    sta $d404,y             ; gate on
    jmp @next
@end:
    lda #$ff
    sta V_IDX,x
    lda voffs,x
    tay
    lda V_WAVE,x
    sta $d404,y
@next:
    dex
    bpl @v
    rts

; ---------------------------------------------------------------- data
!macro nt .hz, .d {         ; SID freq = hz * 2^24 / 985248 (PAL)
    !word .hz * 17.0284
    !byte .d
}
!macro seqend { !byte 0, 0, 0 }

voffs:      !byte 0, 7
dec_lo:     !byte <10000, <1000, <100, <10
dec_hi:     !byte >10000, >1000, >100, >10
rowcol:     !byte 2, 8, 7, 5, 14    ; row 0..4 = score 50..10: red, orange, yellow, green, blue
mcol:       !byte 7, 5, 10, 13
brick_tab:  !byte s_b4-seqdata, s_b3-seqdata, s_b2-seqdata, s_b1-seqdata, s_b0-seqdata

seqdata:
s_paddle:   !byte $40, $04, $00
            +nt 196, 6
            +seqend
s_wall:     !byte $10, $05, $00
            +nt 392, 5
            +seqend
s_launch:   !byte $10, $06, $00
            +nt 330, 3
            +nt 494, 4
            +seqend
s_b0:       !byte $40, $05, $00     ; row 0 (50 points): highest
            +nt 1319, 5
            +seqend
s_b1:       !byte $40, $05, $00
            +nt 1047, 5
            +seqend
s_b2:       !byte $40, $05, $00
            +nt 880, 5
            +seqend
s_b3:       !byte $40, $05, $00
            +nt 698, 5
            +seqend
s_b4:       !byte $40, $05, $00     ; row 4 (10 points): lowest
            +nt 587, 5
            +seqend
s_miss:     !byte $20, $08, $00
            +nt 392, 5
            +nt 330, 5
            +nt 262, 5
            +nt 196, 9
            +seqend
s_over:     !byte $40, $09, $00
            +nt 392, 12
            +nt 330, 12
            +nt 262, 12
            +nt 196, 40
            +seqend
s_win:      !byte $40, $06, $00
            +nt 262, 5
            +nt 330, 5
            +nt 392, 5
            +nt 523, 5
            +nt 392, 3
            +nt 523, 20
            +seqend

!macro ln .pad, .s {        ; one 32-char message line, left padded
    !fill .pad, $20
    !scr .s
    !fill 32-.pad-len(.s), $20
}
msg_lo:     !byte <msg_wait, <msg_play, <msg_over, <msg_won
msg_hi:     !byte >msg_wait, >msg_play, >msg_over, >msg_won
msg_wait:   +ln 7, "b r i c k f a l l"
            +ln 6, "press fire to launch"
            +ln 3, "z / x or joystick 2 to move"
            !scr "wait - fire  "
msg_play:   +ln 0, ""
            +ln 0, ""
            +ln 0, ""
            !scr "playing      "
msg_over:   +ln 11, "game over"
            +ln 9, "no lives left"
            +ln 0, ""
            !scr "game over    "
msg_won:    +ln 12, "you win!"
            +ln 7, "all bricks cleared"
            +ln 0, ""
            !scr "you win!     "
txt_score:  !scr "score"
txt_lives:  !scr "lives"

frame_ch:
!for i, 0, 39 {
    !if i < 3 { !byte CH_PANEL } else { !if i < 4 { !byte CH_WALLL } else { !if i < 36 { !byte $20 } else { !if i < 37 { !byte CH_WALLR } else { !byte CH_PANEL } } } }
}
frame_col:
!for i, 0, 39 {
    !if i < 3 { !byte 9 } else { !if i < 4 { !byte 15 } else { !if i < 36 { !byte 1 } else { !if i < 37 { !byte 15 } else { !byte 9 } } } }
}

; custom characters ($2200 = screen code 64): the ROM-copied glyphs 0-63 sit below
* = $2200
    !byte $ff,$ff,$ff,$ff,$ff,$ff,$55,$00      ; 64 brick, left cap
    !byte $ff,$ff,$ff,$ff,$ff,$ff,$55,$00      ; 65 brick, middle
    !byte $fe,$fe,$fe,$fe,$fe,$fe,$54,$00      ; 66 brick, right cap (1 px gap)
    !byte $fe,$fe,$fe,$00,$ef,$ef,$ef,$00      ; 67 side panel: staggered bricks
    !byte $07,$07,$07,$07,$07,$07,$07,$07      ; 68 left wall bar
    !byte $e0,$e0,$e0,$e0,$e0,$e0,$e0,$e0      ; 69 right wall bar
    !byte $66,$ff,$ff,$ff,$7e,$3c,$18,$00      ; 70 heart

; sprites (VIC sees RAM at $2800+; $1000-$1FFF would be the character ROM)
* = $2800
sprite_ball:                ; 6x6 disc centred on the 4x4 ball box (drawn at -1,-1)
    !byte $78,0,0, $fc,0,0, $fc,0,0, $fc,0,0, $fc,0,0, $78,0,0
    !fill 45, 0
* = $2840
sprite_body:                ; 16 px wide, x-expanded to 32: rounded, 3 notches mark the 4 bounce zones
    !byte $7f,$fe,0
    !byte $ff,$ff,0
    !byte $ff,$ff,0
    !byte $f7,$77,0
    !byte $f7,$77,0
    !byte $f7,$77,0
    !byte $ff,$ff,0
    !byte $7f,$fe,0
    !fill 40, 0
* = $2880
sprite_high:                ; white highlight along the top edge
    !byte $3f,$fc,0
    !fill 61, 0
