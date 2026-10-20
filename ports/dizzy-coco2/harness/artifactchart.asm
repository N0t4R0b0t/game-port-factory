; NTSC artifact-colour chart -- FOR A HUMAN LOOKING AT XROAR.
;
; No headless tool here can answer what this answers. MAME's renderer
; does no cross-colour at all, and the GDB path reads the framebuffer as
; 1bpp and is blind to colour by construction. So this draws every
; period-4 pixel pattern at once and lets the display speak.
;
; 16 horizontal bands, top to bottom, each filled with byte n*$11 for
; n = 0..15 -- i.e. every distinct 4-pixel pattern, tiled. That set
; contains all the period-2 patterns too, so it is the complete artifact
; palette PMODE4 can produce:
;
;   band  1  $00  0000 - solid black   (anchor)
;   band  6  $55  0101 - one artifact colour
;   band 11  $AA  1010 - the other one (opposite subcarrier phase)
;   band 16  $FF  1111 - solid white   (anchor)
;
; and the twelve in between are the uneven patterns, which are where any
; additional hue would have to come from.
;
; SPACE toggles CSS (PIA1 $FF22 bit 3) so both colour sets can be seen
; without a rebuild. Bands are separated by a 1-pixel black line.
;
; WHAT TO LOOK FOR: if any band reads as green, that pattern is worth
; having. If the uneven bands are all just muddy blue/orange/grey, the
; two-phase explanation holds and there is no green to be had this way.
        org $0e00
start
        orcc #$50
        lds #$0100
        lda #$35
        sta $ff03
        sta $ffc0
        sta $ffc3
        sta $ffc5
        sta $ffc6
        sta $ffc8
        sta $ffca
        sta $ffcc
        sta $ffce
        sta $ffd1
        sta $ffd2

        ; 16 bands of 12 rows: 11 rows of pattern, 1 row of black gap.
        ldx #$4000
        clrb                     ; B = band index 0..15
band
        tfr b,a
        lsla
        lsla
        lsla
        lsla                     ; A = n<<4
        pshs b                   ; save the band index for the whole band
        ora ,s                   ; A = (n<<4) | n -- the tiled 4-px pattern
        sta pat
        lda #11
        sta rows
brow
        lda pat
        ldy #32
bcol    sta ,x+
        leay -1,y
        bne bcol
        dec rows
        bne brow
        clra                     ; the 1-row black separator
        ldy #32
bgap    sta ,x+
        leay -1,y
        bne bgap
        puls b
        incb
        cmpb #16
        bne band

css     lda #$f8                 ; start on CSS=1, the shipping colour set
        sta cssval
show    lda $ff22
        anda #$07
        ora cssval
        sta $ff22
        ; SPACE (keyboard column 7, row bit 3) toggles the colour set
        lda #%01111111
        sta $ff02
        lda $ff00
        anda #%00001000
        bne nokey
        lda held
        bne show
        inc held
        lda cssval
        eora #$08
        sta cssval
        bra show
nokey   clr held
        bra show
pat     fcb 0
rows    fcb 0
cssval  fcb 0
held    fcb 0
        end start
