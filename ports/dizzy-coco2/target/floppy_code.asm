; floppy_code.asm -- T0241: the FLOPPY=1 build's resident disk code: the private WD1793 driver
; (target/disk_io.asm, see its header) and the overlay loader.  Included at the start of the
; tape-only region by room36.asm; ~400 bytes against the 3266 the resident title blob used to take.
        include "floppy_layout.asm"
        include "disk_io.asm"

; Overlay counts that depend on the build: the title stream's length is generated.
OVL_TITLE_CNT  equ (TITLE_RESIDENT_LEN+255)/256
        ifgt OVL_TITLE_CNT-OVL_TITLE_CAP
        error "the title overlay no longer fits its DIZZY.OVL slot (floppy_layout.asm OVL_TITLE_CAP)"
        endif

; ovl_tab: track, first sector, sector count -- indexed by overlay id * 3.
ovl_tab
        fcb OVL_TITLE_TRK,OVL_TITLE_SEC,OVL_TITLE_CNT
        fcb OVL_HEART_A_TRK,OVL_HEART_A_SEC,OVL_HEART_A_CAP
        fcb OVL_HEART_B_TRK,OVL_HEART_B_SEC,OVL_HEART_B_CAP
        fcb OVL_SAVE_A_TRK,OVL_SAVE_A_SEC,OVL_SAVE_A_CAP
        fcb OVL_SAVE_B_TRK,OVL_SAVE_B_SEC,OVL_SAVE_B_CAP
        fcb OVL_SPARE_TRK,OVL_SPARE_SEC,OVL_SPARE_CAP
ovl_try fcb 0

; ovl_load: A = overlay id, X = destination.  Reads the overlay's whole sectors from DIZZY.OVL to
; X (so up to 255 bytes past the overlay's end are written too: the destination must have the
; slack).  Three tries (a failed try forces a RESTORE).  Returns A = 0 on success, else the
; controller status.  Clobbers B,X,Y (Y preserved by fd_read, used here).  IRQ stays masked.
ovl_load
        ldb #3
        mul
        leay ovl_tab,pcr
        leay d,y
        pshs x,y                ; S+0 dest, S+2 table entry
        lda #3
        sta ovl_try
ol_retry
        ldy 2,s
        lda ,y
        sta fd_trk
        lda 1,y
        sta fd_sec
        lda 2,y
        sta fd_cnt
        ldx ,s
        jsr fd_read
        tsta
        beq ol_done
        dec ovl_try
        bne ol_retry
ol_done leas 4,s
        rts

; ---------------------------------------------------------------------------------------------
; The heart demo as an overlay (tape_heart_code.asm).  Replaces tape_heart_demo for the two callers
; (actors.asm ud1_win, tape_daisy_code.asm udd_hit).  The demo's code goes to the HIDDEN framebuffer
; at +TW_OFF -- exactly where the completion tune's mixer blob sits, so the blob is overwritten (the
; demo is silent anyway; the meeting path unpacks it again afterwards: tape_win_reblob) -- and its
; scratch page / table stay where they always were, above the blob.  Two blobs on disk, one per
; possible hidden buffer.  If the disk cannot be read the demo is skipped.
; ---------------------------------------------------------------------------------------------
tape_heart_demo
        ldx #BUFB+TW_OFF          ; cur_buf==0: A live -> B hidden
        lda #OVL_HEART_B
        tst cur_buf
        beq th_go
        ldx #BUFA+TW_OFF
        lda #OVL_HEART_A
th_go   pshs x
        jsr ovl_load
        tsta
        puls x
        bne th_skip
        jmp ,x                    ; the overlay ends with rts: back to our caller
th_skip rts

; Unpack the completion-tune blob into the hidden buffer again (tape_win_init's unpack, without
; re-arming the tune: tw_started stays set so the next box RESUMES it).
tape_win_reblob
        ldy tw_base
        ldu #win_mix3_lz
        jmp lz_unpack
        include "floppy_save_res.asm"     ; T0242
floppy_code_end
