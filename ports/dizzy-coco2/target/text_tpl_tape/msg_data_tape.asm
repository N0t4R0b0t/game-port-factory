; T0236: daisyrou1's ending text (notgotallcoins/gotallcoins, X-ALL.TXT
; lines 746/767), hand-written. This is the SOURCE (plain `fcc` text);
; target/msg_data_tape.asm is GENERATED from it by tools/dte (T0215) and
; is what room36.asm `include`s, only inside `if TAPE_ROOMS`.
;
; T0215: the text is DTE-encoded against the shared codebook
; (target/dte_table.asm) WITHOUT contributing to it. tools/dte derives
; ONE codebook from the fixed corpus of target/text_src/*.asm; adding
; text there, even gated, reshuffles code ASSIGNMENTS and changes bytes
; of already-shipped strings (msg_troll's fcb bytes changed in a trial),
; breaking the -run build's byte identity. So this dir
; (target/text_src_tape/) is encode-only: `dte build` rewrites it with
; the table built from the unchanged corpus. Keep text in the 32..=90
; range (dte fails loudly otherwise). Rerun tools/stage_pack.sh to regenerate.
;
; Byte-for-byte transcriptions of X-ALL.TXT's own box positions/sizes/
; text (mpen=16+n, mxy=128+n, drawbox=9, mend=0).

; notgotallcoins (X-ALL.TXT line 746): daisyrou1's nag when coins<30,
; shown via msg_chatter (doendmessages: `jp chatter`, X-ALL.TXT ~3559).
; 4 boxes -- 4 terminators plus the second one ending the run (5 total
; fcb 0 below, same count as the source's own mend,mend tail).
msg_notgotallcoins
        fcb 16+5,128+2,48,9,21,6,16+6
        fcb 128+10,72
        fcc "@orig(X-ALL:747/17)"
        fcb 128+8,80
        fcc "@orig(X-ALL:748/19)"
        fcb 128+9,88
        fcc "@orig(X-ALL:749/18)"
        fcb 128+9,96
        fcc "@orig(X-ALL:750/18)"
        fcb 0
        fcb 16+4,128+6,112,9,24,5,16+3
        fcb 128+12,136
        fcc "@orig(X-ALL:753/22)"
        fcb 128+13,144
        fcc "@orig(X-ALL:754/21)"
        fcb 128+14,152
        fcc "@orig(X-ALL:755/20)"
        fcb 0
        fcb 16+5,128+6,64,9,21,4,16+6
        fcb 128+12,88
        fcc "@orig(X-ALL:758/19)"
        fcb 128+14,96
        fcc "@orig(X-ALL:759/17)"
        fcb 0
        fcb 16+7,128+8,80,9,21,5,16+3
        fcb 128+15,104
        fcc "@orig(X-ALL:762/18)"
        fcb 128+15,112
        fcc "@orig(X-ALL:763/18)"
        fcb 128+13,120
        fcc "@orig(X-ALL:764/20)"
        fcb 0
        fcb 0                     ; second mend: ends the chatter run

; gotallcoins (X-ALL.TXT line 767): daisyrou1's win, shown via
; msg_chatter right after completedgame is set. 5 boxes; box 5 is the
; original's own closing-credits box (X-ALL.TXT 787 and the
; credit line after it), carried over verbatim -- not invented, not trimmed.
msg_gotallcoins
        fcb 16+5,128+2,48,9,24,3,16+6
        fcb 128+8,72
        fcc "@orig(X-ALL:769/22)"
        fcb 0
        fcb 16+4,128+4,128,9,24,3,16+3
        fcb 128+10,152
        fcc "@orig(X-ALL:772/22)"
        fcb 0
        fcb 16+7,128+20,88,9,7,3,16+3
        fcb 128+26,112
        fcc "@orig(X-ALL:775/5)"
        fcb 0
        fcb 16+7,128+4,80,9,23,5,16+3
        fcb 128+10,104
        fcc "@orig(X-ALL:778/21)"
        fcb 128+12,112
        fcc "@orig(X-ALL:779/19)"
        fcb 128+16,120
        fcc "@orig(X-ALL:780/11)"
        fcb 0
        fcb 16+7,128+8,72,9,20,10,16+3
        fcb 128+13,96
        fcc "@orig(X-ALL:783/19)"
        fcb 128+15,104
        fcc "@orig(X-ALL:784/17)"
        fcb 16+4
        fcb 128+16,120
        fcc "@orig(X-ALL:785/16)"
        fcb 128+15,128
        fcc "@orig(X-ALL:786/17)"
        fcb 16+2
        fcb 128+16,140
        fcc "@orig(X-ALL:787/16)"
        fcb 16+5
        fcb 128+16,152
        fcc "@orig(X-ALL:788/16)"
        fcb 0
        fcb 0                     ; second mend: ends the chatter run

; T0239: goawaymess (X-ALL.TXT line 925) -- the miner's first-contact
; line (proxminerou -> proxtrollrou with miner var1==0). One box.
msg_goaway
        fcb 16+5,128+2,48,9,26,5,16+6
        fcb 128+10,72
        fcc "@orig(X-ALL:926/22)"
        fcb 128+12,80
        fcc "@orig(X-ALL:927/20)"
        fcb 128+8,88
        fcc "@orig(X-ALL:928/24)"
        fcb 0

; T0239: killedbyhawk (X-ALL.TXT line 1031), room 49's hawk. Plain, not
; DTE (see this file's header). Same box-less 3-line shape as the
; other kill lines (kill_dizzy_msg prints deadwindow first).
msg_killedbyhawk
        fcb 128+18,88
        fcc "@orig(X-ALL:1031/14)"
        fcb 128+21,96
        fcc "@orig(X-ALL:1032/11)"
        fcb 128+19,104
        fcc "@orig(X-ALL:1033/13)"
        fcb 0

; T0239: puteggbackmess (X-ALL.TXT line 918) -- room 40's egg dropped back
; in the nest (proxegg). One box.
msg_puteggback
        fcb 16+7,128+2,48,9,20,6,16+3
        fcb 128+11,72
        fcc "@orig(X-ALL:920/15)"
        fcb 128+8,80
        fcc "@orig(X-ALL:921/18)"
        fcb 128+12,88
        fcc "@orig(X-ALL:922/14)"
        fcb 128+8,96
        fcc "@orig(X-ALL:923/18)"
        fcb 0

; T0216: rockinwatermess (X-ALL.TXT line 899) -- a rock dropped into room
; 48's river (proxrockrou). One box.
msg_rockinwater
        fcb 16+7,128+2,112,9,26,5,16+3
        fcb 128+6,136
        fcc "@orig(X-ALL:900/26)"
        fcb 128+6,144
        fcc "@orig(X-ALL:901/26)"
        fcb 128+8,152
        fcc "@orig(X-ALL:902/24)"
        fcb 0

; T0218: Dozy (room 45), X-ALL.TXT `dozytalking` (~613), kickdozyagainmess
; (~661) and pushdozymess (~666). All driven through msg_chatter, so every
; stream ends with a second 0. Pens/geometry are the source's own.
;
; (msg_kickdozy, talks 2..4, moved to msg_data_tape_low.asm by T0220.)

; msg_pushdozy: the 5th talk (count == 5): Dozy falls in the water.
msg_pushdozy
        fcb 16+7,128+6,72,9,22,6,16+3
        fcb 128+14,96
        fcc "@orig(X-ALL:667/18)"
        fcb 128+13,104
        fcc "@orig(X-ALL:668/19)"
        fcb 128+11,112
        fcc "@orig(X-ALL:669/21)"
        fcb 128+11,120
        fcc "@orig(X-ALL:670/21)"
        fcb 0
        fcb 0

; T0220: `dozytalking` (the 1st talk) and msg_kickdozy live in
; msg_data_tape_low.asm (TAPE_LOW_REGION).
; T0229: Doug (room 88). X-ALL.TXT dougtalking (796) and goonmysonmess (832), byte-for-byte
; (verified by verify_tape_text). 1st talk: msg_dougtalking via chatter (6 boxes, second 0) and
; the crowbar poke (tape_talk_code.asm); later talks: msg_goonmyson (dougrou, X:2424).
msg_dougtalking
        fcb 16+5,128+2,48,9,25,6,16+6
        fcb 128+9,72
        fcc "@orig(X-ALL:799/22)"
        fcb 128+14,80
        fcc "@orig(X-ALL:800/17)"
        fcb 128+8,88
        fcc "@orig(X-ALL:801/23)"
        fcb 128+9,96
        fcc "@orig(X-ALL:802/22)"
        fcb 0

        fcb 16+4,128+6,104,9,24,6,16+3
        fcb 128+15,128
        fcc "@orig(X-ALL:805/19)"
        fcb 128+13,136
        fcc "@orig(X-ALL:806/21)"
        fcb 128+14,144
        fcc "@orig(X-ALL:807/20)"
        fcb 128+11,152
        fcc "@orig(X-ALL:808/23)"
        fcb 0

        fcb 16+5,128+12,48,9,21,4,16+6
        fcb 128+18,72
        fcc "@orig(X-ALL:811/19)"
        fcb 128+21,80
        fcc "@orig(X-ALL:812/16)"
        fcb 0

        fcb 16+4,128+2,96,9,25,5,16+3
        fcb 128+9,120
        fcc "@orig(X-ALL:815/22)"
        fcb 128+8,128
        fcc "@orig(X-ALL:816/23)"
        fcb 128+9,136
        fcc "@orig(X-ALL:817/22)"
        fcb 0

        fcb 16+5,128+4,64,9,24,6,16+6
        fcb 128+13,88
        fcc "@orig(X-ALL:820/19)"
        fcb 128+10,96
        fcc "@orig(X-ALL:821/22)"
        fcb 128+14,104
        fcc "@orig(X-ALL:822/18)"
        fcb 128+11,112
        fcc "@orig(X-ALL:823/21)"
        fcb 0

        fcb 16+7,128+6,80,9,22,5,16+3
        fcb 128+13,104
        fcc "@orig(X-ALL:826/19)"
        fcb 128+12,112
        fcc "@orig(X-ALL:827/20)"
        fcb 128+12,120
        fcc "@orig(X-ALL:828/20)"
        fcb 0
        fcb 0
msg_goonmyson
        fcb 16+5,128+2,48,9,21,5,16+6
        fcb 128+10,72
        fcc "@orig(X-ALL:833/17)"
        fcb 128+10,80
        fcc "@orig(X-ALL:834/17)"
        fcb 128+8,88
        fcc "@orig(X-ALL:835/19)"
        fcb 0
        fcb 0                     ; second mend: shown via msg_chatter

; T0230: dropwhiskeymess (X:967, droppingwhiskey X:5858) and pickupmanuremess (X:872, pickupmanure
; X:2365), then the inventory names (X:1085-1115) of the tape-table frames and the empty bottle.
msg_dropwhiskey
        fcb 16+2,128+2,48,9,14,7,16+6
        fcb 128+8,72
        fcc "@orig(X-ALL:968/12)"
        fcb 128+9,80
        fcc "@orig(X-ALL:969/11)"
        fcb 128+9,88
        fcc "@orig(X-ALL:970/11)"
        fcb 128+9,96
        fcc "@orig(X-ALL:971/11)"
        fcb 128+11,104
        fcc "@orig(X-ALL:972/9)"
        fcb 0
msg_pickupmanure
        fcb 16+7,128+2,48,9,26,5,16+3
        fcb 128+6,72
        fcc "@orig(X-ALL:873/26)"
        fcb 128+7,80
        fcc "@orig(X-ALL:874/25)"
        fcb 128+8,88
        fcc "@orig(X-ALL:875/24)"
        fcb 0
msg_name_emptybottle
        fcc "@orig(X-ALL:1099/15)"
        fcb 0
msg_name_egg
        fcc "@orig(X-ALL:1083/18)"
        fcb 0
msg_name_potion
        fcc "@orig(X-ALL:1085/20)"
        fcb 0
msg_name_crowbar
        fcc "@orig(X-ALL:1107/16)"
        fcb 0
msg_name_window
        fcc "@orig(X-ALL:1110/14)"
        fcb 0

msg_dozy_end
