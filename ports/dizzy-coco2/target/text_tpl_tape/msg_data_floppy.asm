; T0242: the quick-save boxes.  PORT-ONLY text (the original has no save); SOURCE for the encode-only
; text file target/msg_data_floppy.asm (tools/dte, see msg_data_tape.asm's header for the rules).  Included only
; under FLOPPY.  One box each, shown through msg_begin + msg_box_done (dismissed with SPACE).
; S: written and verified
msg_sv_saved
        fcb 16+5,128+18,96,9,14,3,16+6
        fcb 128+26,120
        fcc "GAME:SAVED"
        fcb 0
; L: read, checked, about to be restored
msg_sv_loaded
        fcb 16+5,128+17,96,9,15,3,16+6
        fcb 128+25,120
        fcc "GAME:LOADED"
        fcb 0
; L: the slot is empty (zeroed) or not a save
msg_sv_none
        fcb 16+5,128+15,96,9,17,3,16+6
        fcb 128+23,120
        fcc "NO:SAVED:GAME"
        fcb 0
; no disk / write protected / read error / checksum
msg_sv_diskerr
        fcb 16+5,128+18,96,9,14,3,16+6
        fcb 128+26,120
        fcc "DISK:ERROR"
        fcb 0
; the build ID in the save is not this build's
msg_sv_version
        fcb 16+5,128+13,96,9,19,4,16+6
        fcb 128+24,120
        fcc "SAVE:IS:FROM"
        fcb 128+21,128
        fcc "ANOTHER:VERSION"
        fcb 0
