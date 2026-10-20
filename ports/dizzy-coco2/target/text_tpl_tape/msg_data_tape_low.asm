; T0220: `dozytalking` (X-ALL.TXT line 613), Dozy's first-talk conversation,
; 8 boxes. SOURCE for the second encode-only text file (see
; msg_data_tape.asm's header for the DTE rules); the generated
; target/msg_data_tape_low.asm is included by room36.asm INSIDE the
; TAPE_LOW_REGION slot (tape_low_slot_start/_end), tape build only.
; The original's leading `defw sleepingpotionhere+room` is NOT part of the
; stream: the port pokes the potion's room in code (dozy_talk, tape_code.asm).
; Shown via msg_chatter, so the run ends with a second 0 (the source's own
; mend,mend tail). Byte-for-byte box positions/sizes/pens.
msg_dozytalking
        fcb 16+4,128+30,48,9,12,4,16+3
        fcb 128+36,72
        fcc "@orig(X-ALL:615/10)"
        fcb 128+38,80
        fcc "@orig(X-ALL:616/8)"
        fcb 0

        fcb 16+7,128+2,80,9,16,5,16+3
        fcb 128+10,104
        fcc "@orig(X-ALL:619/12)"
        fcb 128+8,112
        fcc "@orig(X-ALL:620/14)"
        fcb 128+11,120
        fcc "@orig(X-ALL:621/11)"
        fcb 0

        fcb 16+5,128+12,112,9,17,4,16+6
        fcb 128+18,136
        fcc "@orig(X-ALL:624/15)"
        fcb 128+20,144
        fcc "@orig(X-ALL:625/14)"
        fcb 0

        fcb 16+4,128+2,48,9,26,7,16+3
        fcb 128+9,72
        fcc "@orig(X-ALL:628/23)"
        fcb 128+8,80
        fcc "@orig(X-ALL:629/24)"
        fcb 128+10,88
        fcc "@orig(X-ALL:630/22)"
        fcb 128+12,96
        fcc "@orig(X-ALL:631/20)"
        fcb 128+17,104
        fcc "@orig(X-ALL:632/15)"
        fcb 0

        fcb 16+5,128+2,88,9,14,6,16+6
        fcb 128+8,112
        fcc "@orig(X-ALL:635/12)"
        fcb 128+11,120
        fcc "@orig(X-ALL:636/9)"
        fcb 128+11,128
        fcc "@orig(X-ALL:637/9)"
        fcb 128+10,136
        fcc "@orig(X-ALL:638/10)"
        fcb 0

        fcb 16+5,128+18,112,9,18,5,16+6
        fcb 128+28,136
        fcc "@orig(X-ALL:641/12)"
        fcb 128+24,144
        fcc "@orig(X-ALL:642/16)"
        fcb 128+23,152
        fcc "@orig(X-ALL:643/17)"
        fcb 0

        fcb 16+4,128+2,120,9,17,4,16+3
        fcb 128+10,144
        fcc "@orig(X-ALL:646/13)"
        fcb 128+8,152
        fcc "@orig(X-ALL:647/15)"
        fcb 0

        fcb 16+5,128+2,48,9,16,7,16+6
        fcb 128+9,72
        fcc "@orig(X-ALL:650/13)"
        fcb 128+10,80
        fcc "@orig(X-ALL:651/12)"
        fcb 128+10,88
        fcc "@orig(X-ALL:652/12)"
        fcb 128+9,96
        fcc "@orig(X-ALL:653/13)"
        fcb 128+7,104
        fcc "@orig(X-ALL:654/15)"
        fcb 0

        fcb 16+7,128+8,80,9,20,5,16+3
        fcb 128+14,104
        fcc "@orig(X-ALL:657/18)"
        fcb 128+14,112
        fcc "@orig(X-ALL:658/18)"
        fcb 128+14,120
        fcc "@orig(X-ALL:659/18)"
        fcb 0
        fcb 0                     ; second mend: ends the chatter run

; msg_kickdozy: talks 2..4 (dozyrou, count < 5).
msg_kickdozy
        fcb 16+7,128+10,80,9,17,4,16+3
        fcb 128+18,104
        fcc "@orig(X-ALL:663/13)"
        fcb 128+16,112
        fcc "@orig(X-ALL:664/15)"
        fcb 0
        fcb 0

; ---------------------------------------------------------------------
; T0223: the shopkeeper / bean / beanstalk chain (room 22 -> room 58).
; Byte-for-byte transcriptions of X-ALL.TXT (mpen=16+n, mxy=128+n,
; drawbox=9, mend=0); tools/roompack's verify_tape_text re-reads them.
; Two of the six live here; the other four are in msg_data_tape_low3.asm
; (TAPE_LOW_REGION3), split only to fit the byte budget of each region.
;   msg_shoptalk     shoptalk's stream     (X:577)  thanksforthecowmess ..
;                    letsfaceitmess, via msg_chatter, ends with the second 0;
;                    the leading `defw beanhere+room` is code (cdt_shop)
;   msg_waterbean    throwwateronbeanmess  (X:855)  one box
; ---------------------------------------------------------------------
msg_shoptalk
        fcb 16+5,128+2,80,9,26,4,16+6
        fcb 128+8,104
        fcc "@orig(X-ALL:580/24)"
        fcb 128+9,112
        fcc "@orig(X-ALL:581/23)"
        fcb 0
        fcb 16+4,128+10,120,9,22,4,16+3
        fcb 128+18,144
        fcc "@orig(X-ALL:583/18)"
        fcb 128+15,152
        fcc "@orig(X-ALL:584/21)"
        fcb 0
        fcb 16+5,128+18,48,9,18,5,16+6
        fcb 128+24,72
        fcc "@orig(X-ALL:586/16)"
        fcb 128+24,80
        fcc "@orig(X-ALL:587/16)"
        fcb 128+27,88
        fcc "@orig(X-ALL:588/13)"
        fcb 0
        fcb 16+4,128+2,104,9,15,4,16+3
        fcb 128+11,128
        fcc "@orig(X-ALL:590/10)"
        fcb 128+8,136
        fcc "@orig(X-ALL:591/13)"
        fcb 0
        fcb 16+5,128+6,72,9,24,5,16+6
        fcb 128+13,96
        fcc "@orig(X-ALL:593/21)"
        fcb 128+14,104
        fcc "@orig(X-ALL:594/20)"
        fcb 128+12,112
        fcc "@orig(X-ALL:595/22)"
        fcb 0
        fcb 16+4,128+16,112,9,10,4,16+3
        fcb 128+22,136
        fcc "@orig(X-ALL:597/8)"
        fcb 128+22,144
        fcc "@orig(X-ALL:598/8)"
        fcb 0
        fcb 16+5,128+2,48,9,11,5,16+6
        fcb 128+8,72
        fcc "@orig(X-ALL:600/9)"
        fcb 128+8,80
        fcc "@orig(X-ALL:601/8)"
        fcb 128+7,88
        fcc "@orig(X-ALL:602/9)"
        fcb 16+7,128+12,112,9,15,5,16+3
        fcb 128+18,136
        fcc "@orig(X-ALL:604/13)"
        fcb 128+21,144
        fcc "@orig(X-ALL:605/9)"
        fcb 128+19,152
        fcc "@orig(X-ALL:606/12)"
        fcb 0
        fcb 16+7,128+8,80,9,20,5,16+3
        fcb 128+15,104
        fcc "@orig(X-ALL:608/17)"
        fcb 128+18,112
        fcc "@orig(X-ALL:609/14)"
        fcb 128+15,120
        fcc "@orig(X-ALL:610/17)"
        fcb 0
        fcb 0
msg_waterbean
        fcb 16+7,128+2,48,9,26,8,16+3
        fcb 128+8,72
        fcc "@orig(X-ALL:857/24)"
        fcb 128+13,80
        fcc "@orig(X-ALL:858/19)"
        fcb 16+5
        fcb 128+11,88
        fcc "@orig(X-ALL:859/21)"
        fcb 128+10,96
        fcc "@orig(X-ALL:860/22)"
        fcb 128+12,104
        fcc "@orig(X-ALL:861/20)"
        fcb 128+14,112
        fcc "@orig(X-ALL:862/18)"
        fcb 0
msg_dozylow_end
