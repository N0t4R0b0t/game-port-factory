; T0223: the other four messages of the shopkeeper / bean / beanstalk chain.
; SOURCE for the third encode-only text file (see msg_data_tape.asm's header for
; the DTE rules); the generated target/msg_data_tape_low3.asm is included by
; tape_bean_code.asm INSIDE the TAPE_LOW_REGION3 slot. Byte-for-byte
; transcriptions of X-ALL.TXT (mpen=16+n, mxy=128+n, drawbox=9, mend=0):
;   msg_shopappears  shopkeeperappearsmess (X:562)  single box
;   msg_givingjunk   givingjunkmess        (X:568)  single box
;   msg_stopjunk     stopgivingjunkmess    (X:572)  single box, every 4th junk
;   msg_plantbean    plantbeanmess         (X:864)  2 boxes, one message
msg_shopappears
        fcb 16+7,128+2,96,9,20,5,16+3
        fcb 128+10,120
        fcc "@orig(X-ALL:564/16)"
        fcb 128+10,128
        fcc "@orig(X-ALL:565/16)"
        fcb 128+8,136
        fcc "@orig(X-ALL:566/18)"
        fcb 0
msg_givingjunk
        fcb 16+5,128+2,96,9,25,4,16+6
        fcb 128+10,120
        fcc "@orig(X-ALL:569/21)"
        fcb 128+8,128
        fcc "@orig(X-ALL:570/23)"
        fcb 0
msg_stopjunk
        fcb 16+5,128+2,96,9,19,4,16+6
        fcb 128+10,120
        fcc "@orig(X-ALL:574/15)"
        fcb 128+11,128
        fcc "@orig(X-ALL:575/15)"
        fcb 0
msg_plantbean
        fcb 16+7,128+6,48,9,22,5,16+3
        fcb 128+12,72
        fcc "@orig(X-ALL:865/20)"
        fcb 128+15,80
        fcc "@orig(X-ALL:866/17)"
        fcb 128+15,88
        fcc "@orig(X-ALL:867/17)"
        fcb 16+2,128+2,112,9,16,4,16+6
        fcb 128+8,136
        fcc "@orig(X-ALL:869/14)"
        fcb 128+8,144
        fcc "@orig(X-ALL:870/14)"
        fcb 0

; T0226: the three messages of the knocker / bucket-fill / pickaxe triggers.
; Byte-for-byte transcriptions of X-ALL.TXT (verified by verify_tape_text):
;   msg_usedoorknocker  usedoorknockermess (X:940)  single box, room 84 (proxdoor X:3410)
;   msg_fillbucket      fillbucketmess     (X:909)  single box, room 60 (proxmtbucket X:2982)
;   msg_usepickaxe      usepickaxemess     (X:950)  single box, room 41 (proxpickaxe X:3449)
msg_usedoorknocker
        fcb 16+7,128+2,48,9,20,5,16+3
        fcb 128+12,72
        fcc "@orig(X-ALL:942/14)"
        fcb 128+8,80
        fcc "@orig(X-ALL:943/18)"
        fcb 128+8,88
        fcc "@orig(X-ALL:944/18)"
        fcb 0
msg_fillbucket
        fcb 16+7,128+2,48,9,21,4,16+3
        fcb 128+8,72
        fcc "@orig(X-ALL:910/19)"
        fcb 128+10,80
        fcc "@orig(X-ALL:911/17)"
        fcb 0
msg_usepickaxe
        fcb 16+7,128+2,48,9,22,4,16+3
        fcb 128+9,72
        fcc "@orig(X-ALL:952/19)"
        fcb 128+8,80
        fcc "@orig(X-ALL:953/20)"
        fcb 0

; T0227: userugmess (X:960, proxrug X:3481) -- the rug thrown across room 94's daggers.
; Byte-for-byte transcription of X-ALL.TXT (verified by verify_tape_text).
msg_userug
        fcb 16+7,128+10,80,9,17,6,16+3
        fcb 128+18,104
        fcc "@orig(X-ALL:879/13)"
        fcb 128+17,112
        fcc "@orig(X-ALL:962/14)"
        fcb 128+16,120
        fcc "@orig(X-ALL:963/15)"
        fcb 128+22,128
        fcc "@orig(X-ALL:964/9)"
        fcb 0

; T0227: inventory names the frame-keyed item_name_tab (gameplay.asm) does not have or has wrong for
; the tape build. PURE TEXT, like msg_name_* (show_inventory sets the cursor). X-ALL.TXT:
;   fullbucketmess (X:1102) "@orig(X-ALL:1102/17)"   -- the FULL bucket shares frame 5 with the empty one
;   doorknockermess (X:1106) "@orig(X-ALL:1106/18)" -- frame 21 was "AN OBJECT"
;   rugmess (X:1109) "@orig(X-ALL:1109/16)"           -- frame 12 was "AN OBJECT"
msg_name_fullbucket
        fcc "@orig(X-ALL:1102/17)"
        fcb 0
msg_name_knocker
        fcc "@orig(X-ALL:1106/18)"
        fcb 0
msg_name_rug
        fcc "@orig(X-ALL:1109/16)"
        fcb 0
