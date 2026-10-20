; --------------------------------------------------------------------
; T0078: room-name banner (second row of the status area). One
; prtmessage-ready stream per built room, verbatim from
; extracted/rooms.json's own `name` field -- already padded to a fixed
; 20 characters with the original's own ':'=space/';'=apostrophe/
; '='=hyphen convention (font_data.asm's own header note), matching the
; design sketch's "need 20 chrs for room name" (research/D3-prior-art/
; info/dizzy3_hudplan.jpg). Hand-maintained here, same as
; gap_messages.asm's one-off dialogue text, rather than a new roompack
; codegen path -- nine short strings, never touched by regen_art.sh.
;
; Each stream starts with its OWN room number as a plain data byte (not
; a message opcode -- find_room_name skips it before handing prtmessage
; the pointer), so room_name_table only needs to store addresses, same
; shape as room_desc_table/load_room.
; --------------------------------------------------------------------
msgname_36
        fcb 36
        fcb 128+12,24
        fcc "@orig(X-ALL:438/20)"
        fcb 0
msgname_35
        fcb 35
        fcb 128+12,24
        fcc "@orig(X-ALL:437/20)"
        fcb 0
msgname_51
        fcb 51
        fcb 128+12,24
        fcc "@orig(X-ALL:453/20)"
        fcb 0
msgname_52
        fcb 52
        fcb 128+12,24
        fcc "@orig(X-ALL:454/20)"
        fcb 0
msgname_53
        fcb 53
        fcb 128+12,24
        fcc "@orig(X-ALL:455/20)"
        fcb 0
msgname_54
        fcb 54
        fcb 128+12,24
        fcc "@orig(X-ALL:456/20)"
        fcb 0
msgname_55
        fcb 55
        fcb 128+12,24
        fcc "@orig(X-ALL:457/20)"
        fcb 0
msgname_68
        fcb 68
        fcb 128+12,24
        fcc "@orig(X-ALL:470/20)"
        fcb 0
msgname_69
        fcb 69
        fcb 128+12,24
        fcc "@orig(X-ALL:471/20)"
        fcb 0
msgname_67
        fcb 67
        fcb 128+12,24
        fcc "@orig(X-ALL:469/20)"
        fcb 0
; T0120: 84/85 were built in T0094 without names (the banner's bottom slot
; was blank there); 83/86/100 are new. Text verbatim from rooms.json, padded
; to 20 with ':' the way the others are.
msgname_84
        fcb 84
        fcb 128+12,24
        fcc "@orig(X-ALL:486/20)"
        fcb 0
msgname_85
        fcb 85
        fcb 128+12,24
        fcc "@orig(X-ALL:487/20)"
        fcb 0
msgname_83
        fcb 83
        fcb 128+12,24
        fcc "@orig(X-ALL:485/20)"
        fcb 0
msgname_86
        fcb 86
        fcb 128+12,24
        fcc "@orig(X-ALL:488/20)"
        fcb 0
msgname_100
        fcb 100
        fcb 128+12,24
        fcc "@orig(X-ALL:502/20)"
        fcb 0
msgname_87
        fcb 87
        fcb 128+12,24
        fcc "@orig(X-ALL:489/20)"
        fcb 0
msgname_50
        fcb 50
        fcb 128+12,24
        fcc "@orig(X-ALL:452/20)"
        fcb 0
msgname_56
        fcb 56
        fcb 128+12,24
        fcc "@orig(X-ALL:458/20)"
        fcb 0
msgname_71
        fcb 71
        fcb 128+12,24
        fcc "@orig(X-ALL:473/20)"
        fcb 0
msgname_39
        fcb 39
        fcb 128+12,24
        fcc "@orig(X-ALL:441/20)"
        fcb 0
msgname_23
        fcb 23
        fcb 128+12,24
        fcc "@orig(X-ALL:425/20)"
        fcb 0
msgname_24
        fcb 24
        fcb 128+12,24
        fcc "@orig(X-ALL:426/20)"
        fcb 0
msgname_57
        fcb 57
        fcb 128+12,24
        fcc "@orig(X-ALL:459/20)"
        fcb 0
msgname_72
        fcb 72
        fcb 128+12,24
        fcc "@orig(X-ALL:474/20)"
        fcb 0
msgname_22
        fcb 22
        fcb 128+12,24
        fcc "@orig(X-ALL:424/20)"
        fcb 0
msgname_58
        fcb 58
        fcb 128+12,24
        fcc "@orig(X-ALL:460/20)"
        fcb 0
msgname_59
        fcb 59
        fcb 128+12,24
        fcc "@orig(X-ALL:461/20)"
        fcb 0
msgname_60
        fcb 60
        fcb 128+12,24
        fcc "@orig(X-ALL:462/20)"
        fcb 0

room_name_table
        fdb msgname_36
        fdb msgname_35
        fdb msgname_51
        fdb msgname_52
        fdb msgname_53
        fdb msgname_54
        fdb msgname_55
        fdb msgname_68
        fdb msgname_69
        fdb msgname_67
        fdb msgname_84
        fdb msgname_85
        fdb msgname_83
        fdb msgname_86
        fdb msgname_100
        fdb msgname_87
        fdb msgname_50
        fdb msgname_56
        fdb msgname_71
        fdb msgname_39
        fdb msgname_23
        fdb msgname_24
        fdb msgname_57
        fdb msgname_72
        fdb msgname_22
        fdb msgname_58
        fdb msgname_59
        fdb msgname_60
        fdb 0

; find_room_name: cur_room -> X = ptr to that room's name stream (past
; its own leading room-number byte), or X=0 if this build has no name
; for it (shouldn't happen for a built room -- every one of the 9 above
; has an entry -- but a silent no-op is the same "unreachable and
; harmless" reasoning load_room's own lr_unknown uses).
find_room_name
        pshs a
        lda cur_room
        ldx #room_name_table
frn_scan
        ldu ,x++
        cmpu #0
        beq frn_none
        cmpa ,u
        bne frn_scan
        leau 1,u
        tfr u,x
        puls a
        rts
frn_none
        if TAPE_ROOMS
        ; T0226: the 19 tape-only rooms' names live in TAPE_LOW_REGION4
        ; (text_src_tape/msg_data_tape_low4.asm). Second scan over its own
        ; 0-terminated table; the second terminator (X = tape_names_end)
        ; is the real end.
        cmpx #tape_names_end
        beq frn_none2
        ldx #tape_names_tab
        bra frn_scan
frn_none2
        endif
        ldx #0
        puls a
        rts
