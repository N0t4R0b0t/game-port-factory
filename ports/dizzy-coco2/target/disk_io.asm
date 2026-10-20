; disk_io.asm -- T0241: a private WD1793 driver for the CoCo floppy controller.
;
; Included by BOTH the floppy boot loader (target/floppy_stage1.asm, boot-only, lives in the
; framebuffer-B spare) and the resident game (room36.asm, FLOPPY=1), each assembled separately, so
; the labels below exist twice and never clash.  NO use of Disk BASIC: no ROM mode, no $C004
; DSKCON vector, none of Disk BASIC's RAM ($0600-$0989) or direct page ($EA-$EF) -- the game is in
; all-RAM mode with its stack in $0000-$00FF, where DSKCON's DP block would sit 17-22 bytes deep.
; Decision and measurements: NOTES.md T0241.
;
; Hardware (CoCo FDC cartridge, verified against MAME coco_fdc.cpp and XRoar):
;   $FF40 DSKREG  bit0-2 drive select (one-hot), bit3 motor, bit4 write precompensation,
;                 bit5 double density AND NMI-enable (INTRQ -> NMI only while it is 1),
;                 bit7 HALT enable (CPU is halted whenever DRQ=0; INTRQ clears it)
;   $FF48 command/status  $FF49 track  $FF4A sector  $FF4B data
;
; Reads are multi-sector (command $94) in ONE command per track chunk, the CPU being HALTed between
; data bytes by the controller (no polling, no byte can be lost), and are ended with Force
; Interrupt $D0 (no INTRQ -> no NMI).  The last byte is read with HALT already off, because after
; it nothing would ever release the CPU on the last sector of a track.  Writes are single-sector
; ($A4); their completion IS the INTRQ -> NMI, so the NMI jump at $0109 (what the BASIC ROM's NMI
; vector $FFFC points at) is hooked for the duration of every call and restored after.  An NMI
; during a read means the controller gave up (RNF, CRC, ...) -> error return.
;
; CALL:   fd_trk = physical track 0-34, fd_sec = first sector 1-18, fd_cnt = sector count,
;         X = memory address (destination for fd_read, source for fd_write), then
;         jsr fd_read / jsr fd_write.   Runs with IRQ+FIRQ masked (CC restored).
; RETURN: A = 0 and Z set on success; else A = controller status bits / $FF timeout.
;         fd_trk/fd_sec/fd_cnt are ADVANCED (sector cursor; track 17, the directory, is skipped),
;         so consecutive calls stream through a file.  Clobbers A,B,X; preserves Y,U,DP.
;         fd_keep != 0 leaves the motor on after the call (the boot loader); else it is switched
;         off at the end of every call and the next one pays FD_SPINUP.
; Since the head position is unknown after Disk BASIC, the first call RESTOREs (fd_hd = $FF).

FD_REG    equ $FF40
FD_CMD    equ $FF48
FD_TRKR   equ $FF49
FD_SECR   equ $FF4A
FD_DATR   equ $FF4B
FD_ON     equ $29               ; drive 0 + motor + double density (NMI armed)
FD_ON_SD  equ $09               ; same with bit 5 clear: INTRQ cannot raise NMI (type I commands)
FD_HALTB  equ $80
FD_NMIV   equ $0109             ; JMP at the RAM end of the NMI vector chain
        ifndef FDX_WRITE
FDX_WRITE  equ 1                 ; 0 = read-only build (the boot loader: -DFDX_WRITE=0)
        endif
        ifndef FDX_SAVEVEC
FDX_SAVEVEC equ 1                ; 0 = do not save/restore the 3 bytes at $0109 (boot loader: dead RAM)
        endif
FD_RATE   equ 1                 ; step rate 12 ms (r1r0=01) -- real drives; emulators don't care

fd_trk    fcb 0
fd_sec    fcb 1
fd_cnt    fcb 0
fd_hd     fcb $FF               ; track the head is on, $FF = unknown -> RESTORE first
fd_mot    fcb 0                 ; motor currently on (we turned it on)
fd_keep   fcb 0
        if FDX_WRITE
fd_dir    fcb 0                 ; 0 read, 1 write
fd_wreg   fcb 0
        endif
fd_n      fcb 0
fd_res    fcb 0
fd_yc     fdb 0
fd_sp     fdb 0                 ; S inside the transfer routine: where the NMI exit unwinds to
fd_sp0    fdb 0                 ; S at fd_main entry
        if FDX_SAVEVEC
fd_nmisv  fcb 0,0,0             ; the three bytes of the NMI jump we replaced
        endif

fd_read
        if FDX_WRITE
        clr fd_dir
        bra fd_main
fd_write
        lda #1
        sta fd_dir
        endif
fd_main
        pshs cc,y,u
        orcc #$50
        sts fd_sp0
        if FDX_SAVEVEC
        lda FD_NMIV             ; hook the NMI jump (restored at fd_exit)
        sta fd_nmisv
        ldd FD_NMIV+1
        std fd_nmisv+1
        endif
        lda #$7E
        sta FD_NMIV
        ldd #fd_nmi
        std FD_NMIV+1
        lda #FD_ON_SD
        sta FD_REG
        tst fd_mot
        bne fm_spun
        inc fd_mot
        ldy #0                  ; spin-up: 65536 x 8 cycles = 0.59 s at 0.895 MHz
fm_spin leay -1,y
        bne fm_spin
fm_spun
        lda fd_hd
        cmpa #$FF
        bne fm_chunk
        lda #FD_RATE            ; RESTORE
        sta FD_CMD
        lbsr fd_wait
        tsta
        lbne fm_err
        clr fd_hd
fm_chunk
        tst fd_cnt
        beq fm_ok
        lda #FD_ON_SD
        sta FD_REG
        lda fd_trk
        cmpa fd_hd
        beq fm_there
        sta FD_DATR
        lda #$10+FD_RATE        ; SEEK
        sta FD_CMD
        lbsr fd_wait
        tsta
        bne fm_err
        lda fd_trk
        sta fd_hd
fm_there
        lda #FD_ON
        sta FD_REG
        lda #19                 ; n = sectors left on this track, capped by the count
        suba fd_sec
        cmpa fd_cnt
        bls fm_n
        lda fd_cnt
fm_n
        if FDX_WRITE
        tst fd_dir
        beq fm_n2
        lda #1                  ; writes: one sector per command
fm_n2
        endif
        sta fd_n
        if FDX_WRITE
        tst fd_dir
        bne fm_w
        endif
        lbsr fd_rtrk
        if FDX_WRITE
        bra fm_chk
fm_w    lbsr fd_wsec
        leax -1,x               ; the write loop pre-loads one byte past the sector: step back so X = start + 256
        endif
fm_chk  tsta
        bne fm_err
        lda fd_cnt
        suba fd_n
        sta fd_cnt
        lda fd_sec
        adda fd_n
        sta fd_sec
        cmpa #19
        blo fm_chunk
        lda #1
        sta fd_sec
        lda fd_trk
        inca
        cmpa #17                ; the directory track holds no file data
        bne fm_t
        inca
fm_t    sta fd_trk
        bra fm_chunk
fm_err  ldb #$FF
        stb fd_hd               ; unknown head position: RESTORE next time
        bra fm_exit
fm_ok   clra
fm_exit sta fd_res
        if FDX_SAVEVEC
        lda fd_nmisv
        sta FD_NMIV
        ldd fd_nmisv+1
        std FD_NMIV+1
        endif
        tst fd_keep
        bne fm_on
        clr FD_REG
        clr fd_mot
fm_on   lds fd_sp0
        puls cc,y,u
        lda fd_res
        rts

; wait for the controller to go not-busy (type I / force interrupt); A = 0 ok, $FF timeout.
; Reading the status register also clears INTRQ.  Clobbers Y.
fd_wait
        ldy #0
fw_lp   lda FD_CMD
        bita #1
        beq fw_ok
        leay -1,y
        bne fw_lp
        lda #$FF
        rts
fw_ok   clra
        rts

; the command never produced data (no disk / drive not ready): kill it, report $FF to the caller
        if FDX_WRITE
fd_abort
        lda #$D0
        sta FD_CMD
        lbsr fd_wait
        lda #$FF
        rts
        endif

; read fd_n sectors of the current track starting at fd_sec to X.
fd_rtrk
        lda fd_sec
        sta FD_SECR
        lda fd_n
        deca
        ldb #$FE
        std fd_yc               ; bytes 2 .. n*256-1 come from the halting loop (prepared BEFORE the command: the time
                                ; between byte 1 and the HALT enable is a race against byte 3)
        sts fd_sp               ; NMI exit returns to our caller from here
        lda #$94                ; READ SECTOR, multiple, 15 ms settle
        sta FD_CMD
        exg a,a                 ; give the controller its busy delay
        exg a,a
        if FDX_WRITE
        ldy #0                  ; T0242: timeout (~1.5 s): NO DISK / no index pulses = the command never starts
        endif
; Wait for the FIRST byte by polling, read it AT ONCE (HALT not enabled yet), only then enable HALT for the rest.
; Traps found the hard way: (1) an emulated (MAME) HALT lets ONE more instruction run after it is enabled, so a first
; `lda $FF4B` right after the enable returned stale data and shifted the stream by a byte -> do not let that
; instruction be a data read; (2) the poll loop must stay SHORT (<= ~18 cycles) and nothing slow may sit between byte 1
; and the HALT enable: byte 1's read, and byte 2's, must each fit in one byte time (28 cycles at 0.89 MHz) or the
; controller reports LOST DATA (the symptom was RNF|LD $14 after seconds of retries in MAME).
fr_dq   lda FD_CMD
        bita #2
        bne fr_go
        if FDX_WRITE
        leay -1,y
        bne fr_dq
        lbra fd_abort
        else
        bra fr_dq
        endif
fr_go   lda FD_DATR             ; byte 1
        sta ,x+
        lda #FD_ON+FD_HALTB
        sta FD_REG              ; from here on the CPU halts until each data byte is ready
        ldy fd_yc
fr_lp   lda FD_DATR
        sta ,x+
        leay -1,y
        bne fr_lp
        lda #FD_ON              ; HALT off, then the last byte (DRQ is already up)
        sta FD_REG
        lda FD_DATR
        sta ,x+
        lda #$D0                ; Force Interrupt, no INTRQ: ends the multi-sector command
        sta FD_CMD
        bra fd_wait

        if FDX_WRITE
; write ONE sector (fd_sec of the current track) from X; completion = INTRQ -> NMI -> fd_nmi.
fd_wsec
        lda fd_sec
        sta FD_SECR
        lda #FD_ON
        ldb fd_trk
        cmpb #22
        blo ws_np
        ora #$10                ; write precompensation on the inner tracks
ws_np   sta fd_wreg
        sta FD_REG
        sts fd_sp
        lda #$A4                ; WRITE SECTOR, 15 ms settle
        sta FD_CMD
        exg a,a
        exg a,a
        lda ,x+                 ; first byte ready before the first DRQ
        ldy #0                  ; timeout as in fd_rtrk
fw_dq   ldb FD_CMD              ; poll for the first DRQ, write byte 1 AT ONCE, then HALT for the rest
        bitb #2
        bne fw_go
        leay -1,y
        bne fw_dq
        lbra fd_abort
fw_go   sta FD_DATR             ; byte 1
        lda fd_wreg
        ora #FD_HALTB
        sta FD_REG              ; HALT on (the emulated HALT slips one instruction: the next ones are not data accesses)
        ldy #255                ; bytes 2..256
        lda ,x+                 ; byte 2
fw_wl   sta FD_DATR
        lda ,x+
        leay -1,y
        bne fw_wl
fw_spin bra fw_spin             ; wait for INTRQ -> NMI
        endif

; NMI = the controller finished (write) or gave up (read).  Unwind to the routine's caller.
fd_nmi
        lds fd_sp
        lda FD_CMD              ; status; clears INTRQ
        if FDX_WRITE
        ldb fd_dir
        bne nm_w
        endif
        anda #$9C               ; not ready, RNF, CRC, lost data
        rts
        if FDX_WRITE
nm_w    anda #$FC               ; + write protect, write fault
        rts
        endif
