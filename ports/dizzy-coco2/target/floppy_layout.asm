; floppy_layout.asm -- T0241: WHERE EVERYTHING LIVES ON DIZZY'S DISK.
; Shared by room36.asm (via floppy_code.asm), floppy_stage1.asm and tools/floppy_pack.sh, which
; cross-checks every number below against the .dsk it just built (dskwriter locate) -- change a
; size here and the build tells you which constant to fix.
;
; RS-DOS: granule g = 9 sectors = half a track; physical track = g/2 (+1 from granule 34 on, the
; directory is track 17), first sector (g%2)*9+1.  Files are laid out CONTIGUOUSLY in this order:
;
;   granules 0-3   DIZZY.OVL  36 sectors, tracks 0-1: the on-demand overlays (slots below)
;   granules 4-5   DIZZY.SAV  18 sectors, track 2: the quick-save slot, pre-allocated, zeroed (T0242)
;   granules 6-..  DIZZY.DAT  the boot image: every DECB segment of room36_floppy.bin, in ascending
;                             address order, each starting on a sector boundary (floppy_stage1.asm)
;   (after DAT)    DIZZY.BIN  the loader DECB that Disk BASIC's LOADM reads
;
; Overlay slots (sector index within DIZZY.OVL -> physical track/sector; capacity in sectors):
;   id 0 OVL_TITLE   idx 0   track 0 sec 1    cap 14  the packed title image + music (TITLE_RESIDENT_LEN) -> TITLE_LZ_BUF
;   id 1 OVL_HEART_A idx 14  track 0 sec 15   cap 2   the heart demo (tape_heart_code.asm) assembled for BUFA+TW_OFF
;   id 2 OVL_HEART_B idx 16  track 0 sec 17   cap 2   ... and for BUFB+TW_OFF (which buffer is hidden depends on cur_buf)
;   id 3 OVL_SAVE_A  idx 18  track 1 sec 1    cap 3   T0242 quick save/load (target/floppy_save.asm) for BUFA+TW_OFF
;   id 4 OVL_SAVE_B  idx 21  track 1 sec 4    cap 3   ... and for BUFB+TW_OFF
;   id 5 OVL_SPARE   idx 24  track 1 sec 7    cap 12  (reserved)
OVL_TITLE      equ 0
OVL_HEART_A    equ 1
OVL_HEART_B    equ 2
OVL_SAVE_A     equ 3
OVL_SAVE_B     equ 4
OVL_SPARE      equ 5

OVL_TITLE_TRK   equ 0
OVL_TITLE_SEC   equ 1
OVL_TITLE_CAP   equ 14
OVL_HEART_A_TRK equ 0
OVL_HEART_A_SEC equ 15
OVL_HEART_A_CAP equ 2
OVL_HEART_B_TRK equ 0
OVL_HEART_B_SEC equ 17
OVL_HEART_B_CAP equ 2
OVL_SAVE_A_TRK  equ 1
OVL_SAVE_A_SEC  equ 1
OVL_SAVE_A_CAP  equ 3
OVL_SAVE_B_TRK  equ 1
OVL_SAVE_B_SEC  equ 4
OVL_SAVE_B_CAP  equ 3
OVL_SPARE_TRK   equ 1
OVL_SPARE_SEC   equ 7
OVL_SPARE_CAP   equ 12

OVL_GRAN       equ 0
OVL_GRANS      equ 4
SAV_GRAN       equ 4
SAV_GRANS      equ 2
SAV_TRK        equ 2
SAV_SEC        equ 1
SAV_SECS       equ 18
DAT_GRAN       equ 6
DAT_TRK        equ 3
DAT_SEC        equ 1
