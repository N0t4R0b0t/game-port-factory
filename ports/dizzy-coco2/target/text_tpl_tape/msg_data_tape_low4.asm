; T0226: room-name banners for the 19 tape-only rooms (TAPE build only).
; SOURCE for the fourth encode-only text file (see msg_data_tape.asm's header for
; the DTE rules); the generated target/msg_data_tape_low4.asm is included by
; room36.asm INSIDE the TAPE_LOW_REGION4 slot (data only, reached by absolute
; address from ui_room_names.asm's find_room_name fallback).
;
; Same format as target/text_src/ui_room_names.asm's msgname_NN streams: the
; room's own number as a plain data byte (find_room_name skips it), then
; mxy+12,24 (the 20-char banner position), the name verbatim from
; extracted/rooms.json `name` (20 chars, ':'=space ';'=apostrophe '='=hyphen),
; then mend. tape_names_tab is the 0-terminated address table the fallback scans.
msgname_74
        fcb 74
        fcb 128+12,24
        fcc "@orig(X-ALL:476/20)"
        fcb 0
msgname_75
        fcb 75
        fcb 128+12,24
        fcc "@orig(X-ALL:477/20)"
        fcb 0
msgname_63
        fcb 63
        fcb 128+12,24
        fcc "@orig(X-ALL:465/20)"
        fcb 0
msgname_91
        fcb 91
        fcb 128+12,24
        fcc "@orig(X-ALL:493/20)"
        fcb 0
msgname_92
        fcb 92
        fcb 128+12,24
        fcc "@orig(X-ALL:494/20)"
        fcb 0
msgname_45
        fcb 45
        fcb 128+12,24
        fcc "@orig(X-ALL:447/20)"
        fcb 0
msgname_48
        fcb 48
        fcb 128+12,24
        fcc "@orig(X-ALL:450/20)"
        fcb 0
msgname_49
        fcb 49
        fcb 128+12,24
        fcc "@orig(X-ALL:451/20)"
        fcb 0
msgname_94
        fcb 94
        fcb 128+12,24
        fcc "@orig(X-ALL:496/20)"
        fcb 0
msgname_89
        fcb 89
        fcb 128+12,24
        fcc "@orig(X-ALL:491/20)"
        fcb 0
msgname_41
        fcb 41
        fcb 128+12,24
        fcc "@orig(X-ALL:443/20)"
        fcb 0
msgname_73
        fcb 73
        fcb 128+12,24
        fcc "@orig(X-ALL:475/20)"
        fcb 0
msgname_88
        fcb 88
        fcb 128+12,24
        fcc "@orig(X-ALL:490/20)"
        fcb 0
msgname_93
        fcb 93
        fcb 128+12,24
        fcc "@orig(X-ALL:495/20)"
        fcb 0
msgname_40
        fcb 40
        fcb 128+12,24
        fcc "@orig(X-ALL:442/20)"
        fcb 0
msgname_46
        fcb 46
        fcb 128+12,24
        fcc "@orig(X-ALL:448/20)"
        fcb 0
msgname_31
        fcb 31
        fcb 128+12,24
        fcc "@orig(X-ALL:433/20)"
        fcb 0
msgname_47
        fcb 47
        fcb 128+12,24
        fcc "@orig(X-ALL:449/20)"
        fcb 0
msgname_77
        fcb 77
        fcb 128+12,24
        fcc "@orig(X-ALL:479/20)"
        fcb 0
tape_names_tab
        fdb msgname_74
        fdb msgname_75
        fdb msgname_63
        fdb msgname_91
        fdb msgname_92
        fdb msgname_45
        fdb msgname_48
        fdb msgname_49
        fdb msgname_94
        fdb msgname_89
        fdb msgname_41
        fdb msgname_73
        fdb msgname_88
        fdb msgname_93
        fdb msgname_40
        fdb msgname_46
        fdb msgname_31
        fdb msgname_47
        fdb msgname_77
        fdb 0
tape_names_end

; T0228: Daisy's meeting in her prison (room 94). Byte-for-byte transcriptions of
; X-ALL.TXT (verified by verify_tape_text; mpen=16+n, mxy=128+n, drawbox=9, mend=0):
;   msg_gottodaisy   gottodaisymess (X:732)  single box, shown under tune 3 (daisyrou X:3499)
;   msg_daisyruns    daisyrunsmess  (X:736)  single box, after the heart demo (daisyrou X:3513)
msg_gottodaisy
        fcb 16+5,128+2,48,9,17,5,16+6
        fcb 128+8,72
        fcc "@orig(X-ALL:733/15)"
        fcb 128+8,80
        fcc "@orig(X-ALL:734/15)"
        fcb 128+9,88
        fcc "@orig(X-ALL:735/14)"
        fcb 0
msg_daisyruns
        fcb 16+7,128+4,64,9,24,9,16+3
        fcb 128+13,88
        fcc "@orig(X-ALL:738/19)"
        fcb 128+10,96
        fcc "@orig(X-ALL:739/22)"
        fcb 128+11,104
        fcc "@orig(X-ALL:740/21)"
        fcb 128+9,112
        fcc "@orig(X-ALL:741/23)"
        fcb 128+11,120
        fcc "@orig(X-ALL:742/21)"
        fcb 128+10,128
        fcc "@orig(X-ALL:743/22)"
        fcb 128+14,136
        fcc "@orig(X-ALL:744/18)"
        fcb 0

; T0229: Dylan (room 59) and Doug (room 88), the two Yolkfolk that still showed
; Denzil's text. Byte-for-byte transcriptions of X-ALL.TXT (verified by
; verify_tape_text). talkingtopeople (X:2378): the 1st talk runs the person's
; stream via chatter (so it ends with a second 0), later talks call dylanrou /
; dougrou (X:2424/2427) -> windowrou, a single box (one 0).
;   msg_dylantalking dylantalking (X:674)   3 boxes, 1st talk (leading `defw duffmem` poke is a no-op)
;   msg_trance       trancemess   (X:691)   Dylan, every later talk
;   (Doug's msg_dougtalking and msg_goonmyson are in msg_data_tape.asm, the tape-only
;   region: LOW4 is too small for all four.)
msg_dylantalking
        fcb 16+5,128+2,48,9,18,4,16+6
        fcb 128+10,72
        fcc "@orig(X-ALL:676/14)"
        fcb 128+7,80
        fcc "@orig(X-ALL:677/17)"
        fcb 0

        fcb 16+4,128+4,96,9,24,6,16+3
        fcb 128+10,120
        fcc "@orig(X-ALL:680/22)"
        fcb 128+12,128
        fcc "@orig(X-ALL:681/20)"
        fcb 128+10,136
        fcc "@orig(X-ALL:682/22)"
        fcb 128+14,144
        fcc "@orig(X-ALL:683/18)"
        fcb 0

        fcb 16+5,128+12,72,9,19,5,16+6
        fcb 128+18,96
        fcc "@orig(X-ALL:686/17)"
        fcb 128+18,104
        fcc "@orig(X-ALL:687/17)"
        fcb 128+18,112
        fcc "@orig(X-ALL:688/17)"
        fcb 0
        fcb 0
msg_trance
        fcb 16+7,128+4,80,9,24,4,16+3
        fcb 128+14,104
        fcc "@orig(X-ALL:692/18)"
        fcb 128+9,112
        fcc "@orig(X-ALL:693/23)"
        fcb 0
        fcb 0                     ; second mend: shown via msg_chatter, like msg_kickdozy

; T0227: holdingholemess (X:980, checkholdinghole X:2520): one box with an inline pen change.
        if TAPE_HOLE
msg_holdinghole
        fcb 16+2,128+2,48,9,16,7,16+6
        fcb 128+8,72
        fcc "@orig(X-ALL:981/8)"
        fcb 16+4
        fcc "@orig(X-ALL:981#1/6)"
        fcb 128+9,80
        fcc "@orig(X-ALL:982/13)"
        fcb 128+10,88
        fcc "@orig(X-ALL:983/12)"
        fcb 128+8,96
        fcc "@orig(X-ALL:984/14)"
        fcb 128+10,104
        fcc "@orig(X-ALL:985/12)"
        fcb 0
        endif
