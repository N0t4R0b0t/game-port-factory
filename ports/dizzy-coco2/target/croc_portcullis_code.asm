; T0161: update_crocodile + update_portcullis, CODE ONLY, split out of
; gameplay.asm the same way T0148 moved update_dragon -- staged to
; CODE_DEST (block D, same block as target/dragon_code.asm, included
; right after it inside room36.asm's `org CODE_DEST` section) so the
; RAW bytes they used to cost below $8000 go back into the shared
; title-hole delivery pool (NOTES.md "The port is 58 packed bytes short
; of room 25" / T0159), at the cost of their (smaller) PACKED size
; inside block D.
;
; WHY THESE TWO: both are called from exactly one site each (room36.asm
; mainloop's `jsr update_crocodile` / `jsr update_portcullis`,
; gameplay-only, long after new_game/show_title have run) and each is
; fully self-contained -- their own locals (uc_n/uc_slot and
; up_n/up_gate_hi/up_switch_hi/up_dc) are moved WITH the code, exported
; via staged_syms.asm exactly like dragon_code.asm's locals, because
; T0148/T0153's own postmortem applies here too: any reference from a
; frozen (pass-1) staged block to a low-memory address is unsound unless
; that address is itself pass-invariant. Nothing outside this file reads
; uc_n/uc_slot/up_n/up_gate_hi/up_switch_hi/up_dc (verified by grep
; before moving) EXCEPT gameplay_init's `clr up_dc` -- safe for the same
; reason gameplay_init already clears dragon_swing/dragon_delay/
; dragon_asleep/dragon_fire (also staged): gameplay_init only ever runs
; from new_game, strictly after boot_code.asm's unpack_c/unpack_d have
; already unpacked every staged block, so a plain absolute write to a
; CODE_DEST-relative address is safe there the same way a read is.
;
; update_crocodile ALSO reads `killed` (resident, unmoved -- shared with
; every other death-state check) and CROC_FACE_*/CROC_BITE_* (moved here
; with it: `equ` constants, used only inside this routine, confirmed by
; grep -- nothing else references them).
;
; update_portcullis does NOT bring PORT_OPEN_Y/PORT_CLOSED_Y with it:
; those stay resident in gameplay.asm because draw_gate (room36.asm's
; per-room draw callback, called every pass in room 51 via Y, active or
; not) and room36.asm's own damage-rect code both read them too, and
; draw_gate is NOT moved -- it is reached indirectly through the actor
; draw table, not the single hardcoded call site this task's brief
; requires (update_crocodile/update_portcullis/update_dagger, "called
; ONLY from the main loop during gameplay"). draw_gate's own locals
; (gate_last_a/b, dg_y/dg_col/dg_s/dg_lp) were never touched by
; update_portcullis's code either way (confirmed by grep) so the split
; is clean: update_portcullis owns up_n/up_gate_hi/up_switch_hi/up_dc,
; draw_gate owns its own set, and PORT_OPEN_Y/PORT_CLOSED_Y are the only
; things both sides read -- left where the still-resident reader is.
;
; SAME BUILD RULE AS dragon_code.asm: `org CODE_DEST` directly, NOT a
; phase block -- lwasm 4.24 miscomputes relative branch offsets inside a
; phase block whenever the physical org and the phase target differ
; (dragon_code.asm's own header has the repro). This file has branches
; (beq/bne/blo/bhs/lbeq), so the same rule applies. No `rmb` at the end:
; every local here is already an explicit `fcb`/`fdb`, so there is
; nothing to convert.
;
; Covered by: update_crocodile -- harness/actorlife.lua's own croc
; assertion (var1's 0..7 mouth-cycle advance, `inca` in uc_anim -- the
; T0151 table shows this line commented out fails the croc line and
; passes everything else, exactly the "wrong address into zero-filled
; RAM no-ops instead of crashing" signature T0148 taught this harness to
; catch). update_portcullis -- harness/portcullis_block.lua (referenced,
; not duplicated, per T0151's own actor table).
; --------------------------------------------------------------------
CROC_FACE_X     equ 168          ; the "which way am I looking" box
CROC_FACE_Y     equ 80
CROC_FACE_W     equ 80
CROC_FACE_H     equ 100
CROC_BITE_X     equ 152          ; the mouth itself
CROC_BITE_Y     equ 140
CROC_BITE_W     equ 24
CROC_BITE_H     equ 10

update_crocodile
        lda cur_room
        cmpa #53
        beq uc_inroom
        rts
uc_inroom
        lda killed
        beq uc_alive
        rts
uc_alive
        ; find this room's crocodile slot
        ldx #actor_ram
        lda #ACTOR_COUNT
        sta uc_n
uc_find
        lda ,x
        cmpa cur_room
        bne uc_findnext
        lda 1,x
        cmpa #ROU_CROCODILE
        beq uc_found
uc_findnext
        leax ACTOR_STRIDE,x
        dec uc_n
        bne uc_find
        rts
uc_found
        stx uc_slot

        lda 6,x                  ; delaycounter
        inca
        anda #7
        sta 6,x
        bne uc_bite              ; only 1 tick in 8 animates

        ; facing: bit 7 of the colour byte, from the big proximity box
        lda #CROC_FACE_X
        sta ah_bx
        lda #CROC_FACE_Y
        sta ah_by
        lda #CROC_FACE_W
        sta ah_bw
        lda #CROC_FACE_H
        sta ah_bh
        jsr uc_hit
        ldx uc_slot
        tsta
        beq uc_faceset
        lda 7,x
        ora #$80
        sta 7,x
        bra uc_anim
uc_faceset
        lda 7,x
        anda #$7f
        sta 7,x

uc_anim
        lda 5,x                  ; var1
        cmpa #255
        beq uc_frame             ; tied: frozen, mouth shut
        inca
        anda #7
        sta 5,x
uc_frame
        lda 5,x
        ldb #123
        cmpa #240
        bhs uc_setframe          ; tied
        cmpa #3
        blo uc_setframe
        bita #1
        beq uc_setframe
        incb                     ; 124: mouth open
uc_setframe
        stb 4,x
        ; T0066: NO full-screen invalidation here. Forcing both buffers
        ; to repaint the whole room to animate one 16x32 sprite cost
        ; ~80ms a pass at 1x CPU against a 66.7ms budget, on 14% of
        ; passes -- two slow frames every eight, which is precisely the
        ; "room 53 is slow and a bit choppy" this was reported as.
        ; draw_actors now tracks what each buffer last drew for the
        ; gator and forces just ITS box, the same per-buffer trick
        ; draw_flames has used since T0033.

uc_bite
        ldx uc_slot
        lda 4,x
        bita #1
        bne uc_done              ; odd frame = 123 = mouth shut = harmless
        lda #CROC_BITE_X
        sta ah_bx
        lda #CROC_BITE_Y
        sta ah_by
        lda #CROC_BITE_W
        sta ah_bw
        lda #CROC_BITE_H
        sta ah_bh
        jsr uc_hit
        tsta
        beq uc_done
        ; the original drops Dizzy into the mouth before the death
        ; animation plays (`ld a,69-32 / ld (x),a` -- his x is in 4px
        ; units, so 37*4 = 148 pixels -- and `ld a,160 / ld (y),a`)
        lda #148
        sta dizzy_x
        lda #160
        sta dizzy_y
        clr dizzy_dy
        ldx #msg_croceaten
        jsr kill_dizzy_msg
uc_done
        rts

; aabb_hit clobbers X on some paths; the croc's slot pointer has to
; survive it.
uc_hit
        pshs x,y
        jsr aabb_hit
        puls x,y
        rts

uc_n        fcb 0
uc_slot     fdb 0

; --------------------------------------------------------------------
; update_portcullis: see gameplay.asm's own T0068/T0115 comment (still
; there, kept with PORT_OPEN_Y/PORT_CLOSED_Y and draw_gate) for the full
; mechanism writeup. Code only, moved here per this file's own header.
; --------------------------------------------------------------------
update_portcullis
        lda cur_room
        cmpa #51
        beq up_inroom
        rts
up_inroom
        ; find both actors: the gate itself and its switch
        ldd #0
        std up_gate_hi
        std up_switch_hi
        ldx #actor_ram
        lda #ACTOR_COUNT
        sta up_n
up_find
        lda ,x
        cmpa cur_room
        bne up_findnext
        lda 1,x
        cmpa #ROU_PORTCULLIS
        bne up_notgate
        stx up_gate_hi
        bra up_findnext
up_notgate
        cmpa #ROU_PORTSWITCH
        bne up_findnext
        stx up_switch_hi
up_findnext
        leax ACTOR_STRIDE,x
        dec up_n
        bne up_find

        ldd up_gate_hi
        lbeq up_done              ; this build's room 51 has no gate slot
        ldd up_switch_hi
        lbeq up_done              ; ...or no switch: nothing to wire up

        ; --- the switch: DOWN key, one-shot, gated on its own v1 ------
        ldx up_switch_hi
        lda 5,x                   ; switch's own v1: 0 = not yet thrown
        bne up_gatecheck
        lda keyflags
        bita #2                   ; DOWN
        beq up_gatecheck
        ldy up_switch_hi          ; actor_hit reads the slot via Y
        pshs x
        jsr actor_hit             ; near the switch's own sprite?
        puls x
        tsta
        beq up_gatecheck
        lda #1
        sta 5,x                   ; thrown -- permanently, matches the
                                    ; source's own one-shot ("it breaks")
        ldx up_gate_hi
        lda #-2
        sta 5,x                   ; portswitchrou: var1 = -2, rising...
        lda #2
        sta 6,x                   ; ...with delay 2
        jsr msg_begin
        ldx #msg_throwswitch
        jsr msg_box_done       ; T0221 (was 9 bytes inline)

up_gatecheck
        ; T0115: X-ALL.TXT portcullisrou, literally. v1 (offset 5) is the
        ; original's var1 (-2 rising, +2 falling, 0 = never thrown), offset
        ; 6 its `delay`: delayrou runs a mover every delay-th tick, every
        ; tick when 0. One original tick is ~3 frames and one pass here is
        ; ~4, so ticks map to passes 1:1. Measured in the real game
        ; (harness/zx_film.lua logging the gate's RAM record): after the
        ; throw it rises 2px per 2 ticks to y=96, slams shut 2px per tick,
        ; then reopens 2px per 4 ticks -- forever.
        ;
        ; This replaces T0102's 1px/pass oscillation plus a "filled" latch,
        ; which was built on reading the original's non-erasing draw as a
        ; trail. The original's draw OVERWRITES (plot mode 0), and the gate
        ; sprite's two blank bottom rows are what erase its lower edge as
        ; it rises -- so the gate OPENS, rather than growing a column.
        ldx up_gate_hi
        lda 5,x
        beq up_done
        lda 6,x                   ; delayrou
        beq up_move
        inc up_dc
        lda up_dc
        cmpa 6,x
        blo up_done
        clr up_dc
up_move
        lda 5,x
        adda 3,x
        sta 3,x
        cmpa #PORT_OPEN_Y
        bne up_nottop
        clr 6,x                   ; turnportcullisplusdelay: delay 0, slams
        bra up_turn
up_nottop
        cmpa #PORT_CLOSED_Y
        bne up_kill
        lda #4
        sta 6,x                   ; delay 4: reopens slowly
up_turn
        neg 5,x                   ; negvar1
up_kill
        ldx up_gate_hi
        ldy up_gate_hi            ; actor_hit reads the slot via Y
        jsr actor_hit             ; touching the moving spike right now?
        tsta
        beq up_done
        ldx #msg_portcullis
        jsr kill_dizzy_msg
up_done
        rts

up_n            fcb 0
up_gate_hi      fdb 0
up_switch_hi    fdb 0
up_dc           fcb 0     ; the gate's delaycounter
