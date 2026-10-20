; floppy_stage1.asm -- T0241: the floppy boot loader, DIZZY.BIN (a plain DECB binary).
;
;   LOADM"DIZZY":EXEC        (Disk BASIC loads this ONE small block, then jumps here)
;
; Everything after that is ours: the game's segments are read straight off the disk with the
; private driver (target/disk_io.asm), no Disk BASIC, no ROM mode.  The machine is put in all-RAM
; mode first, so segments at $8000+ are read DIRECTLY to their final addresses (the tape loader's
; bounce buffer and copy loop are gone).
;
; DISK FORMAT (tools/floppy_pack.sh): DIZZY.DAT holds every segment of the floppy image, each one
; starting on a sector boundary and padded to whole sectors, in ASCENDING address order.  The table
; below (generated: target/floppy_segs.asm) lists (destination, sector count); the file is read
; sequentially.  The padding of a segment's last sector spills up to 255 bytes past the segment's
; end -- harmless because every later segment is higher (it overwrites the spill) and
; tools/floppy_pack.sh HARD-FAILS if the spill could reach this loader, the I/O page or a
; segment loaded earlier.
;
; Placement: LOADER_ORG (-D, tools/floppy_pack.sh) -- framebuffer B's spare, above block B's last
; sector, below the $7800 block.  Window/guards are in floppy_pack.sh.

        include "floppy_layout.asm"     ; DAT_TRK / DAT_SEC (where DIZZY.DAT starts)

        org LOADER_ORG

floppy_boot
        orcc #$50               ; no IRQ/FIRQ (the game never uses them either)
        lds #LOADER_STACK       ; top of this loader's window; BASIC's stack is left behind
        sta $ffdf               ; SAM all-RAM: $8000+ is real RAM from now on
        ifdef BOOT_MARKS        ; TEST BUILD ONLY (harness/floppy_timing_loader.sh): time the load on the tape recording
        lda $FF21
        ora #8                  ; tape motor on
        sta $FF21
        lbsr bm_mark
        endif
        lda #1
        sta fd_keep             ; motor stays on for the whole load
        lda #DAT_TRK
        sta fd_trk
        lda #DAT_SEC
        sta fd_sec
        ldu #seg_table
fb_next
        ldx ,u++                ; destination, 0 = end of table
        beq fb_done
        lda ,u+                 ; sector count
        sta fd_cnt
        jsr fd_read             ; preserves U; advances fd_trk/fd_sec
        tsta
        bne fb_err
        bra fb_next
fb_done
        lda #GAME_NMI0          ; the driver's NMI hook sits on $0109-$010B: put the image's bytes back
        sta $0109
        ldd #GAME_NMI12
        std $010A
        ifdef RES_FD_MOT
        lda #1                  ; HAND THE DRIVE OVER: the resident driver's first call (show_title's overlay read, a
        sta RES_FD_MOT          ; moment from now) finds the motor already spinning (no 0.59 s spin-up) and the head
        lda fd_hd               ; where we left it (no RESTORE); it switches the motor off itself when it is done.
        sta RES_FD_HD
        else
        clr fd_keep
        clr fd_mot
        clr FD_REG              ; motor off, drives deselected
        endif
        ifdef BOOT_MARKS
        lbsr bm_mark            ; (tape motor stays ON: the title music that follows is recorded too -- xroar quits on -timeout)
        endif
        jmp GAME_EXEC           ; the game's `start`

        ifdef BOOT_MARKS
fb_err  bra fb_err
bm_mark ldb #6
bm_mk1  lda #$FC
        sta $FF20
        lbsr bm_dly
        clra
        sta $FF20
        lbsr bm_dly
        decb
        bne bm_mk1
        rts
bm_dly  ldx #200
bm_dl1  leax -1,x
        bne bm_dl1
        rts
        else
; Failure: "E" + the status byte in hex on the text screen (Disk BASIC's own screen is still up).
fb_err
        ldx #$05E0
        ldb #5                  ; screen code of 'E'
        stb ,x+
        pshs a
        lsra
        lsra
        lsra
        lsra
        bsr fb_dig
        puls a
        bsr fb_dig
fb_hang bra fb_hang
fb_dig  anda #$0F
        adda #$30
        cmpa #$3A
        blo fb_dd
        suba #$39               ; A-F -> screen codes 1-6
fb_dd   sta ,x+
        rts

        endif

        include "disk_io.asm"

        include "floppy_segs.asm"       ; seg_table: fdb dest / fcb sectors ... fdb 0

LOADER_END equ *
        end floppy_boot
