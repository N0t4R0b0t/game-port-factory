; --------------------------------------------------------------------
; T0240: CoCo analog joystick, TAPE build only (room36.asm: scankeys ends in
; `jmp joy_fire`, the main loop's re-sample calls `jsr joy_walk`).
;
; RIGHT joystick (the port games use), X axis = walk, fire button = jump.
;   pot:   6-bit successive approximation, DAC $FF20 bits 7..2, comparator
;          $FF00 bit 7 (1 = pot above the DAC, as Color BASIC's JOYIN $A9DE).
;          Right X is mux select 00 = the SAME select the DAC sound path needs
;          (CA2 $FF01 bit3 = 0, CB2 $FF03 bit3 = 0), so the mux is never
;          moved away from sound.  The sound enable ($FF23 bit3) is muted
;          for the read, the DAC is parked at 0 afterwards (pt_rest's own
;          rest level) and pt_level is cleared to match, so a pass costs no
;          click once the DAC is at rest.
;   fire:  $FF00 bits 0 (right) / 1 (left), active low, read with every
;          keyboard column released ($FF02 = $FF).  scankeys ORs it into
;          keyflags as SPACE (bit 4), so message boxes, inventory select and
;          the title accept it; joy_walk turns it into UP (bit 0) = jump.
; Speed is SLOWER-ONLY.  d = deflection 0..31 from the centre (right: x-32,
; left: 31-x, so the two sides mirror exactly):
;   d < 8                dead zone (stand still; this is also where the stick
;                        is "armed": a stick that never rests in the dead
;                        zone -- nothing plugged in reads pegged -- is ignored)
;   n = d/4 - 1, at most 4:  8..11 -> 1, 12..15 -> 2, 16..19 -> 3, >= 20 -> 4
; joy_acc += n; a step (the keyboard's one 4 px step) happens when it reaches
; 4 (then -4): n = 4 steps every update (exactly the key), 3 -> 3 of 4,
; 2 -> every other, 1 -> every 4th.  Back at the centre joy_acc := 3, so the
; first update of any deflection steps at once.  FIRE with the stick outside
; the dead zone forces the step too: a jump latches its direction at
; take-off at full speed, or none.
; Placement (the three regions are nearly full): joy_fire in TAPE_LOW_REGION2
; (always mapped: scankeys runs on the title too), joy_walk in the tape-only
; region, joy_read + the three variables in TAPE_LOW_REGION3.
; --------------------------------------------------------------------
JOY_DEAD        equ 8

; joy_walk: main-loop re-sample, after the `killed` gate.  B = the keyflags
; bits to add (direction, then UP for fire).
joy_walk
        tst killed
        bne jw_ret
        jsr joy_read             ; A = pot 0..63
        ldb #8                   ; keyflags RIGHT
        suba #32
        bpl jw_have
        coma                     ; left: d = 31 - x
        ldb #4                   ; keyflags LEFT
jw_have cmpa #JOY_DEAD
        blo jw_centre
        tst joy_armed
        beq jw_noaxis
        lsra
        lsra
        deca                     ; n = d/4 - 1 (1..6)
        cmpa #4
        bls jw_n
        lda #4
jw_n    adda joy_acc
        cmpa #4
        blo jw_nostep
        suba #4                  ; step this update (B = direction)
        bra jw_store
jw_nostep
        tst joy_f
        bne jw_store             ; fire: take off at full speed anyway
        clrb
jw_store sta joy_acc
        bra jw_tail
jw_centre
        lda #3
        sta joy_acc
        sta joy_armed            ; any non-zero
jw_noaxis
        clrb
jw_tail tst joy_f
        beq jw_ok
        orb #1                   ; UP = jump
jw_ok   orb keyflags
        stb keyflags
jw_ret  rts

