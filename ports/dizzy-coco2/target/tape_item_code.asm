; T0226: door knocker, empty-bucket fill, pickaxe + rock, TAPE build only.
; Assembled into TAPE_LOW_REGION3 right after tape_bean_code.asm (room36.asm),
; same rules: branches inside this file may be short, every reference to
; anything outside it (and to tape_bean_code.asm) uses jsr/jmp/lbra/lbeq.
;
; X-ALL.TXT (cited by line). Port boxes use the port's own conversion,
; (x-32)*4 and w*4, y/h unscaled (same as T0216/T0223/T0239):
;   proxdoor 3410: room 84 box (34,160,4,16) -> (8,160,16,16) (= DOOR_KNOCK_*,
;     the same box as proxknox). The dropped door knocker (frame 21, room 89)
;     sets doorhere+room = 255 and shows usedoorknockermess. The knocker is NOT
;     consumed (the routine does not touch ix). The door is an ordinary base-
;     table actor (frame 177, ROU_DOOR): while it is in room 84 it blocks the
;     bottom-left exit to room 83 (logic_low.asm T0134); room 255 removes both
;     the sprite and its solid body (build_solid_actors only takes this room's
;     actors) and update_door's scan finds nothing. actors_init restores it.
;   proxmtbucket 2982: room 60 box (46,144,4,16) -> (56,144,16,16). The EMPTY
;     bucket (frame 5, room 83, base slot buckethere): bucket.room = 255,
;     turnonfullbucket = the NEXT record's room := 60 -- the full bucket, which
;     starts in room 255 in the original (orig_room 255, X:1647) and whose x,y
;     (56,144) it already has. fillbucketmess. The full bucket's prox is
;     proxfullbucket (room 58 only), the empty one's is proxmtbucket (room 60
;     only), so the two are told apart by RECORD, not by frame (both are 5).
;     The -run build still has the full bucket in room 60 from the start (its
;     base-table data is shared); the tape build zeroes it at reset time
;     (ti_reset, called from bean_reset <- tape_state_reset <- reset_tape_actors).
;   proxpickaxe 3449: room 41 box (36,101,12,20) -> (16,101,48,20). The dropped
;     pickaxe (frame 9, room 87) writes A into rockhere+room (A is whatever
;     proximitycollide left, never 41 in practice) and shows usepickaxemess; the
;     pickaxe is not consumed either. Here: rock room := 255. rockhere is X:1705
;     (room 41, routine crowbar = static, colour 2+8 = solid, frame 146, raw
;     (36,101) -> px (16,101)): it sits at the left edge of room 41.

FRAME_KNOCKER   equ 21
FRAME_DOOR      equ 177
FRAME_ROCK      equ 146
FRAME_RUG       equ 12
FRAME_DAGGER    equ 169

full_bucket     fdb 0                ; the base-table record of the FULL bucket (set by ti_reset)

ti_box_door     fcb DOOR_KNOCK_X,DOOR_KNOCK_Y,DOOR_KNOCK_W,DOOR_KNOCK_H
ti_box_mt       fcb 56,144,16,16
ti_box_pick     fcb 16,101,48,20
ti_box_rug      fcb 8,152,16,16

; new_game (via bean_reset): the full bucket is not in the world until the
; empty one is filled. Find it (frame 5, starts in room 60) so nothing here
; hard-codes its slot, hide it and remember where it is.
ti_reset
        ldx #actor_ram
        ldb #ACTOR_COUNT
tr_l
        lda 4,x
        cmpa #FRAME_BUCKET
        bne tr_n
        lda ,x
        cmpa #60
        bne tr_n
        lda #255
        sta ,x
        stx full_bucket
        rts
tr_n
        leax ACTOR_STRIDE,x
        decb
        bne tr_l
        rts

; check_drop_trigger (via cdt_tape): frame 5, X = the dropped bucket record.
cdt_bucket
        cmpx full_bucket
        lbeq ct_water                ; the full one: proxfullbucket (tape_bean_code.asm)
        lda cur_room                 ; the empty one: proxmtbucket
        cmpa #60
        bne ti_ret
        ldu #ti_box_mt
        bsr ti_box
        beq ti_ret
        lda #255
        sta ,x                       ; the empty bucket is consumed
        ldx full_bucket
        lda #60
        sta ,x                       ; ... and the full one appears here
        jsr msg_begin
        ldx #msg_fillbucket
        bra ti_say

; check_drop_trigger (via cdt_tape): frame 21, X = the dropped knocker.
cdt_knocker
        lda cur_room
        cmpa #84
        bne ti_ret
        ldu #ti_box_door
        bsr ti_box
        beq ti_ret
        ldx #actor_ram
        ldb #ACTOR_COUNT
        lda #FRAME_DOOR
        bsr ti_find
        ldy #msg_usedoorknocker
        bra ti_remove

; check_drop_trigger (via cdt_tape): frame 9, X = the dropped pickaxe.
cdt_pickaxe
        lda cur_room
        cmpa #41
        bne ti_ret
        ldu #ti_box_pick
        bsr ti_box
        beq ti_ret
        ldx #actor_init_tape
        ldb #ACTOR_COUNT_tape
        lda #FRAME_ROCK
        bsr ti_find
        ldy #msg_usepickaxe
; X = the record to remove (0: none), Y = the message
ti_remove
        cmpx #0
        beq ti_rm_none
        lda #255
        sta ,x
ti_rm_none
        pshs y
        jsr msg_begin
        puls x
ti_say
        jsr msg_box_done
        jmp force_redraw
ti_ret
        rts

; X = table, B = record count, A = frame -> X = first record with that frame,
; or 0 when there is none.
ti_find
        pshs a
tf_l
        lda 4,x
        cmpa ,s
        beq tf_hit
        leax ACTOR_STRIDE,x
        decb
        bne tf_l
        ldx #0
tf_hit
        puls a,pc

; U = a 4-byte box (x,y,w,h). Z set = Dizzy is NOT in it. X preserved.
ti_box
        lda ,u
        sta ah_bx
        lda 1,u
        sta ah_by
        lda 2,u
        sta ah_bw
        lda 3,u
        pshs x
        jsr aabb_test
        puls x
        rts

; T0227: check_drop_trigger (via cdt_tape): frame 12, X = the dropped rug.
; proxrug X:3481: room 94 box (34,152,4,16) -> (8,152,16,16). The rug is
; consumed (ix+room = 255) and the two carpet records, which follow it in the
; table (original slot order: rug, carpethere, carpethere1), come into room 94.
; The carpets are solid (colour 2, bit 6 clear) 32x8 slabs at y=152: Dizzy
; standing on one has his feet ON the daggers' top (152) and actor_hit misses.
cdt_rug
        lda cur_room
        cmpa #94
        bne ti_ret
        ldu #ti_box_rug
        bsr ti_box
        beq ti_ret
        lda #94
        sta 8,x
        sta 16,x
        ldy #msg_userug
        bra ti_remove

; update_switch1 (tape_code.asm) calls this every pass in room 94: daggerrou
; X:3395 for the two frame-169 records (room 94 has no respawn override).
ud94_daggers
        ldx #actor_init_tape
        ldb #ACTOR_COUNT_tape
        lda #FRAME_DAGGER
        bsr ti_find
        tfr x,y
        jsr actor_hit
        tsta
        bne ud94_kill
        leay ACTOR_STRIDE,y
        jsr actor_hit
        tsta
        beq ud94_ret
ud94_kill
        ldx #msg_daggers
        jmp kill_dizzy_msg
ud94_ret
        rts

; T0227: actors.asm try_pickup / tp_take (TAPE build), A = the picked actor's frame,
; Y = its record. Carry set = handled here (nothing is picked up), clear = take it
; normally, A unchanged.
;   105 the shopkeeper (X-ALL pickupablerou `cp 105 / jp z,inventoryrou`, T0223): DOWN next
;       to him opens the inventory (the port only when something is carried); he is never taken.
;   1   the bag (pickingupbag X:2361): `ld (bag),a` + the record leaves the world and the
;       inventory screen opens -- NOT a carried item. The usable slots grow 3 -> 4 (inv_cap;
;       actors_init resets it to 3 on a new game).
FRAME_BAG       equ 1
tape_take_hook
        cmpa #105
        beq tth_inv
        cmpa #3
        beq tth_manure
        cmpa #FRAME_BAG
        bne tth_no
        lda #255
        sta ,y                       ; the bag leaves the world ...
        lda #4
        sta inv_cap                  ; ... and the inventory holds four
        jsr force_redraw
        jsr show_inventory
        bra tth_done
tth_inv
        lda inv
        beq tth_done
        jsr show_inventory
tth_done
        orcc #1                      ; C = handled
        rts
tth_manure                       ; T0230: pickupmanure X:2365 -- never picked up. var1 = 0: set
        tst 5,y                      ; it to 1 and show pickupmanuremess; var1 <> 0 (1, or 2 once the
        bne tth_inv                  ; bean is watered): tryputtingdown1, the inventory
        inc 5,y
        jsr msg_begin
        ldx #msg_pickupmanure
        jsr msg_box_done
        bra tth_done
tth_no
        andcc #$FE                   ; C clear
        rts
