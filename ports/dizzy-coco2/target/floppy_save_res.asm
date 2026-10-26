; floppy_save_res.asm -- T0242: the RESIDENT half of quick save/load (FLOPPY build; included by floppy_code.asm).
; Keys S (save) and L (load), polled at the top of every main-loop pass (so they are inherently ignored in message
; boxes, the inventory, the title, the death box and the heart demo: none of those run the main loop), and accepted
; only while Dizzy stands on the floor in normal play.  The disk work is the OVERLAY target/floppy_save.asm,
; loaded into the hidden framebuffer just before use (the two-blob scheme of the heart demo).
        include "msg_data_floppy.asm"      ; generated (tools/dte): msg_sv_saved/loaded/none/diskerr/version

SV_KEY_S   equ %11110111           ; $FF02 strobe: S is column PB3, row PA2 ($FF00 bit 2)
SV_KEY_L   equ %11101111           ; L is column PB4, row PA1 (bit 1)

save_poll
        ldb #SV_KEY_S
        stb $ff02
        lda $ff00
        bita #4
        beq sp_save
        ldb #$ff                   ; L shares row PA1 with the LEFT joystick button: with every column released
        stb $ff02                  ; a low row-1 bit can only be the button -> then L is not a key press
        lda $ff00
        bita #2
        lbeq sp_ret
        ldb #SV_KEY_L
        stb $ff02
        lda $ff00
        bita #2
        lbne sp_ret
        lda #1                     ; load
        bra sp_go
sp_save clra                       ; save
sp_go   tst killed
        lbne sp_ret                 ; normal play only: alive,
        tst jump_on
        lbne sp_ret                 ; not jumping,
        tst dizzy_floor
        lbeq sp_ret                 ; standing on something,
        tst well_mode
        lbne sp_ret                 ; not in the well,
        tst troll_launching
        lbne sp_ret                 ; not being thrown by the troll,
        tst completedgame
        lbne sp_ret                 ; not at the end.
        tsta
        bne sv_do_load
; ---- save ----
        jsr sv_open
        lbne sv_fail
        ldx sv_base
        jsr ,x                     ; sv_save
        tsta
        bne sv_fail
        sta sv_code                ; 0
        ldx #msg_sv_saved
        lbra sv_box_rel
; ---- load ----
sv_do_load
        jsr sv_open
        bne sv_fail
        ldx sv_base
        jsr 3,x                    ; sv_read: nothing applied yet
        tsta
        bne sv_fail
        lda #10
        sta sv_code                ; 10 = read ok, about to apply
        jsr msg_begin              ; the box over the CURRENT picture; the staged image survives in the hidden buffer
        ldx #msg_sv_loaded
        jsr sv_box_plain           ; T0258: NOT msg_box_done -- save/load is not the original's windowrou, so it must not run box_reset
        ldx sv_base
        jsr 6,x                    ; sv_apply
        lda #20
        sta sv_code                ; 20 = applied, rebuilding (test hook)
        lda room_load_seq          ; load_room (box_reset) bumps room_load_seq, and hawk/dagger/... reset themselves when it differs
        ldb flame_ctr              ; from their own copy ("room just entered"), and restarts the flame / water counters and the
        pshs d                     ; dragon's breath: a load is NOT an entry (T0258: box_reset made those four part of load_room's
        lda water_ctr              ; entry reset, T0255 had the counters), so keep the saved values of all four
        ldb dragon_fire
        pshs d
        jsr load_room              ; cur_room is the saved one now: rebuild the room exactly as entering it does
        puls d
        sta water_ctr
        stb dragon_fire
        puls d
        sta room_load_seq
        stb flame_ctr
        jsr force_redraw           ; both buffers repainted whole
        clr rat_sv_hdr_a           ; save-unders belong to the old screen
        clr rat_sv_hdr_b
        lda #255
        sta ui_last_lives          ; banner repaint (lives / coins / room name)
        sta ui_last_coins
        sta ui_last_room
        jsr sv_relkeys
        lds #$0100                 ; a fresh main-loop pass, as new_game enters it
        jmp mainloop
sp_ret  rts

sv_box_plain
        jsr prtmessage
        jsr msg_wait_dismiss
        jmp force_redraw

; A = 1 no save, 2 other build, 3 disk/damaged/unreadable (or sv_open's error: nonzero)
sv_fail
        sta sv_code                ; test hook: the last result (0 ok, 1 no save, 2 other build, 3 disk/damaged, else a driver status)
        ldx #msg_sv_none
        cmpa #1
        beq sv_box_rel
        ldx #msg_sv_version
        cmpa #2
        beq sv_box_rel
        ldx #msg_sv_diskerr
sv_box_rel
        jsr msg_begin
        jsr sv_box_plain           ; T0258: NOT msg_box_done -- save/load is not the original's windowrou, so it must not run box_reset
        jsr sv_relkeys
        rts

; sv_open: load the overlay for the hidden framebuffer; sv_base = its address; A = 0 ok (Z set)
sv_open
        ldx #BUFB+TW_OFF           ; cur_buf==0: A live -> B hidden
        lda #OVL_SAVE_B
        tst cur_buf
        beq so_go
        ldx #BUFA+TW_OFF
        lda #OVL_SAVE_A
so_go   stx sv_base
        jsr ovl_load
        tsta
        rts

; wait until S and L are both up (the box was dismissed with SPACE; the player may still hold the key)
sv_relkeys
        jsr wait_vsync
        ldb #SV_KEY_S
        stb $ff02
        lda $ff00
        bita #4
        beq sv_relkeys
        ldb #SV_KEY_L
        stb $ff02
        lda $ff00
        bita #2
        bne sr_done
        ldb #$ff                   ; row 1 low under the L column: a key, or the left joystick button?
        stb $ff02
        lda $ff00
        bita #2
        bne sv_relkeys             ; columns released and the bit is up: it was the L key
sr_done rts

sv_base fdb 0
sv_code fcb $ff                    ; last save/load result (harness/quicksave.lua reads it)
