; --------------------------------------------------------------------
; Message streams relocated into the $5800 gap (T0058).
;
; Pure data, reached only by an absolute `ldx #label`, so where they
; live is arbitrary -- and the $0E00-$4000 region below the framebuffer
; is the one that actually runs out (T0058 pushed it 65 bytes past
; $4000 and silently overwrote dizzy_frame35, exactly the corruption
; class the regen_art.sh audit note warns about). Put new message text
; HERE, not next to the routine that shows it.
; --------------------------------------------------------------------
; X-ALL.TXT's `youfoundcoinmess` (line 1053), byte-for-byte.
msg_foundcoin
        fcb 16+5,128+16,64,9,12,5,16+3
        fcb 128+22,88
        fcc "@orig(X-ALL:1055/10)"
        fcb 16+6
        fcb 128+23,96
        fcc "@orig(X-ALL:1056/9)"
        fcb 128+26,104
        fcc "@orig(X-ALL:1057/6)"
        fcb 0

; X-ALL.TXT's `croceatenmess` (line 1027), byte-for-byte. No drawbox --
; it prints INSIDE deadwindow's box, which is why it starts straight in
; with a position opcode.
msg_croceaten
        fcb 128+19,88
        fcc "@orig(X-ALL:1027/13)"
        fcb 128+19,100
        fcc "@orig(X-ALL:1028/13)"
        fcb 0

; X-ALL.TXT's `killedbyflame` (line 1019), byte-for-byte. Like
; msg_croceaten it prints INSIDE deadwindow's box, so no drawbox.
msg_killedbyflame
        fcb 128+18,88
        fcc "@orig(X-ALL:1019/14)"
        fcb 128+19,100
        fcc "@orig(X-ALL:1020/13)"
        fcb 0

; X-ALL.TXT's `throwswitchmess` (line 878), byte-for-byte -- T0068,
; room 51's switch. Its own drawbox, shown via msg_begin/prtmessage/
; msg_wait_dismiss like the troll's, not inside another box.
msg_throwswitch
        fcb 16+7,128+2,48,9,15,5,16+3
        fcb 128+8,72
        fcc "@orig(X-ALL:879/13)"
        fcb 128+8,80
        fcc "@orig(X-ALL:880/13)"
        fcb 128+8,88
        fcc "@orig(X-ALL:881/13)"
        fcb 0

; X-ALL.TXT's `killedbyportcullis` (line 997), byte-for-byte. No drawbox
; -- same as msg_croceaten, drawn inside deadwindow's own box.
msg_portcullis
        fcb 128+16,88
        fcc "@orig(X-ALL:998/16)"
        fcb 128+16,96
        fcc "@orig(X-ALL:999/16)"
        fcb 128+18,104
        fcc "@orig(X-ALL:1000/14)"
        fcb 0

; T0070: X-ALL.TXT's `dragonkilledmess` (line 1008), byte-for-byte.
msg_dragon
        fcb 128+16,88
        fcc "@orig(X-ALL:1008/16)"
        fcb 128+16,96
        fcc "@orig(X-ALL:1009/16)"
        fcb 128+20,104
        fcc "@orig(X-ALL:1010/12)"
        fcb 0

; X-ALL.TXT's `killedbydaggersmess` (line 1046), byte-for-byte.
msg_daggers
        fcb 128+14,88
        fcc "@orig(X-ALL:1047/18)"
        fcb 128+15,100
        fcc "@orig(X-ALL:1048/17)"
        fcb 0

; T0071: X-ALL.TXT's `dragonflameskilledmess` (line 1013), byte-for-byte.
msg_dragonfire
        fcb 128+17,88
        fcc "@orig(X-ALL:1014/15)"
        fcb 128+17,96
        fcc "@orig(X-ALL:1015/15)"
        fcb 128+20,104
        fcc "@orig(X-ALL:1016/12)"
        fcb 0

; T0123: X-ALL.TXT's `armorogkilledmess` (line 992), byte-for-byte, drawn
; inside deadwindow's box like the other hazards' lines.
msg_armorog
        fcb 128+18,88
        fcc "@orig(X-ALL:993/14)"
        fcb 128+17,100
        fcc "@orig(X-ALL:994/15)"
        fcb 0

; T0123: X-ALL.TXT's `fedarmorog` (line 883), byte-for-byte.
msg_fedarmorog
        fcb 16+7,128+2,48,9,18,4,16+3
        fcb 128+8,72
        fcc "@orig(X-ALL:884/16)"
        fcb 128+10,80
        fcc "@orig(X-ALL:885/14)"
        fcb 0

; T0124: X-ALL.TXT's `keyinmachine` (line 903), byte-for-byte.
msg_keyinmachine
        fcb 16+7,128+2,48,9,24,5,16+3
        fcb 128+8,72
        fcc "@orig(X-ALL:905/22)"
        fcb 128+13,80
        fcc "@orig(X-ALL:906/17)"
        fcb 128+8,88
        fcc "@orig(X-ALL:907/22)"
        fcb 0

; T0124: X-ALL.TXT's `obstructingliftmess` (line 955), byte-for-byte.
msg_obstructlift
        fcb 16+2,128+14,80,9,14,4,16+6
        fcb 128+21,104
        fcc "@orig(X-ALL:957/11)"
        fcb 128+21,112
        fcc "@orig(X-ALL:958/11)"
        fcb 0

; T0124: X-ALL.TXT's `killedbyliftmess` (line 1003), byte-for-byte, inside
; deadwindow's box like the other hazards' lines.
msg_liftcogs
        fcb 128+17,88
        fcc "@orig(X-ALL:1003/15)"
        fcb 128+18,96
        fcc "@orig(X-ALL:1004/14)"
        fcb 128+17,104
        fcc "@orig(X-ALL:1005/15)"
        fcb 0

; T0133: X-ALL.TXT's `dragonasleepmess` (line 887), byte-for-byte -- room
; 54's dragon, shown by proxsleeprou when the @orig(X-ALL:642/16) is dropped
; in the box.
msg_dragonasleep
        fcb 16+7,128+2,48,9,21,6,16+3
        fcb 128+8,72
        fcc "@orig(X-ALL:888/19)"
        fcb 128+10,80
        fcc "@orig(X-ALL:889/17)"
        fcb 128+9,88
        fcc "@orig(X-ALL:890/18)"
        fcb 128+8,96
        fcc "@orig(X-ALL:891/19)"
        fcb 0

; T0075: X-ALL.TXT's `usecrowbarmess` (line 946), byte-for-byte -- room
; 55's well lid.
msg_crowbar
        fcb 16+7,128+2,48,9,19,5,16+3
        fcb 128+8,72
        fcc "@orig(X-ALL:947/17)"
        fcb 128+8,80
        fcc "@orig(X-ALL:948/17)"
        fcb 128+13,88
        fcc "@orig(X-ALL:949/12)"
        fcb 0

; T0134: X-ALL.TXT's `knockandentermess` (line 931), byte-for-byte -- room
; 84's door. doorrou reaches it with `jp chatter`, so it is a two-box
; conversation and ends with two zero bytes (msg_chatter's contract).
msg_knockandenter
        fcb 16+2,128+2,96,9,17,3,16+6
        fcb 128+8,120
        fcc "@orig(X-ALL:933/15)"
        fcb 0
        fcb 16+7,128+6,48,9,22,5,16+3
        fcb 128+14,72
        fcc "@orig(X-ALL:936/18)"
        fcb 128+11,80
        fcc "@orig(X-ALL:937/21)"
        fcb 128+11,88
        fcc "@orig(X-ALL:938/21)"
        fcb 0
        fcb 0

; T0100: Denzil's conversation. X-ALL.TXT's `denziltalking` (~1730),
; which is what `talkingtopeople` reaches for a person Dizzy has not
; spoken to yet. The source's second, later exchange (`stereoess` --
; "@orig(X-ALL:724/18) HIS STEREO, @orig(X-ALL:726/15)") needs the original's
; `talkbefore` per-person state table, which this port does not have
; yet; first contact is the line that matters and the one that makes him
; read as a character instead of an item.
msg_denzil
; T0198: the FULL four-box exchange, X-ALL.TXT `denziltalking` (~695),
; driven through msg_chatter -- the original's own `chatter` loop, which
; it reserves for real conversations. Playtest: "the Denzil conversation
; is just one text box, there should be a few, like on the troll."
;
; It WAS one box: T0100 condensed it to two lines because the source's
; 26x5 box "rendered truncated -- line 2 stops mid-word and line 3 never
; appears". Re-tested at full width and it renders complete; whatever
; that was, it is not the box geometry. The condensed version and its
; note are gone.
;
; Boxes alternate speaker, exactly as the source does:
;   1 Dizzy  2 Denzil  3 Dizzy  4 Denzil (and hands the rope back)
; Pens: the source alternates 4/3 (Dizzy) and 5/6 (Denzil). On 1bpp only
; ink-vs-paper survives and 4/3 drew white-on-white, so both speakers use
; the 5/6 pairing msg_troll established. Kept as two distinct pens so the
; data stays shaped like the original's.
;
; EVERY box ends with a 0, and the RUN ends with a second 0 -- that is
; msg_chatter's terminator and the source's own `mend,mend`.
        fcb 16+5,128+2,96,9,26,5,16+6
        fcb 128+8,120
        fcc "@orig(X-ALL:697/24)"
        fcb 128+10,128
        fcc "@orig(X-ALL:698/22)"
        fcb 128+12,136
        fcc "@orig(X-ALL:699/20)"
        fcb 0

        fcb 16+5,128+2,48,9,24,6,16+6
        fcb 128+9,72
        fcc "@orig(X-ALL:702/21)"
        fcb 128+10,80
        fcc "@orig(X-ALL:703/20)"
        fcb 128+9,88
        fcc "@orig(X-ALL:704/21)"
        fcb 128+15,96
        fcc "@orig(X-ALL:705/15)"
        fcb 0

        fcb 16+5,128+4,96,9,24,7,16+6
        fcb 128+10,120
        fcc "@orig(X-ALL:708/22)"
        fcb 128+12,128
        fcc "@orig(X-ALL:709/20)"
        fcb 128+13,136
        fcc "@orig(X-ALL:710/19)"
        fcb 128+11,144
        fcc "@orig(X-ALL:711/21)"
        fcb 128+12,152
        fcc "@orig(X-ALL:712/20)"
        fcb 0

        fcb 16+5,128+2,48,9,26,7,16+6
        fcb 128+10,72
        fcc "@orig(X-ALL:715/22)"
        fcb 128+9,80
        fcc "@orig(X-ALL:716/23)"
        fcb 128+11,88
        fcc "@orig(X-ALL:717/21)"
        fcb 128+12,96
        fcc "@orig(X-ALL:718/20)"
        fcb 128+9,104
        fcc "@orig(X-ALL:719/23)"
        fcb 0

        fcb 0                     ; end of the run (the source's 2nd mend)

; T0105: X-ALL.TXT `croctiedmess`, box geometry and all three lines its
; own. Pens 5/6 for the reason msg_denzil documents.
msg_croctied
        fcb 16+5,128+2,48,9,19,5,16+6
        fcb 128+11,72
        fcc "@orig(X-ALL:895/14)"
        fcb 128+10,80
        fcc "@orig(X-ALL:896/15)"
        fcb 128+8,88
        fcc "@orig(X-ALL:897/17)"
        fcb 0
