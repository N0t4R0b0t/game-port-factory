# Fantasy World Dizzy -- complete solution path vs the TAPE build

Analysis 2026-10-02; **STATUS UPDATE T0230: row 27 COMPLETE (black hole ON, whiskey/drunk, manure message) + inventory names of egg/potion/crowbar/window frame/empty bottle IMPLEMENTED -- NOTES.md `## T0230`**; **STATUS UPDATE T0227: row 19 (rug + room 94 daggers/carpets) IMPLEMENTED, row 27 PART (bag IMPLEMENTED, black hole built but OFF by `TAPE_HOLE`, whiskey + manure not built), inventory names fixed for tape items -- NOTES.md `## T0227`**; **STATUS UPDATE T0226: rows 18, 21, 22 (pickaxe + rock, door knocker, bucket fill) and the banners of the 19 tape-only rooms are IMPLEMENTED -- NOTES.md `## T0226`**; **STATUS UPDATE T0223 (same day)**: rows 20, 23, 24 (shopkeeper, plant, water + beanstalk) are now IMPLEMENTED -- see the 'T0223 status' block under section 5 and NOTES.md `## T0223`. The text below keeps the ORIGINAL audit findings (what was missing) for the record; statuses in the tables are annotated. Sources: `research/D3-prior-art/original_source/X-ALL.TXT`
(cited as `X:<line>`), `extracted/actors.json`, `target/actor_data*.asm`,
`target/text_src/{gameplay,actors}.asm`, `target/tape_code.asm`, `target/tape_win_code.asm`,
`target/logic_low.asm`, `target/armorog_lifts_dagger_code.asm`, `target/room36_tape.map`, NOTES.md
(T0198-T0221 sections), `tools/roomview.py 58`. Cost numbers come from `tools/solution_audit.py`
(re-run it to reproduce the message/sprite/coin tables).

Labels: **MEASURED** = counted from a shipped symbol/source/frame table. **GUESS** = estimated.
Map rule (X:6298, NOTES T0060): room = row*16 + col, **up = +16**, left/right = -1/+1; adjacency is
arithmetic only, the art decides what is walkable. Walkability below is NOT re-walked; it is derived
from triggers except where a NOTES harness is cited.

## 0. Findings that change the picture (read first)

1. **(FIXED T0223)** **The bean did not exist in the tape build.** No `beanhere` record in `actor_data.asm` or
   `actor_data_tape.asm`, no sprite for frame 2, no shopkeeper (frame 105) record. So the trade that
   produces the bean cannot happen, and the plant/water/beanstalk chain cannot run.
2. **(FIXED T0223)** **Room 58 had no way up** (roomview: only the y=176 ground and a 16 px ledge at y=144, x36..52;
   nothing near the top line y=66). Room 74 (giant beanstalk, 58+16) exists but is only reachable once the
   original's room-1 overlay (beanstalk drawn into room 58, `checkbeanstalk` X:5478) is built. There is
   no `room1_data` in `target/`.
3. **(FIXED T0226 in the tape build)** **The empty-bucket/door/knocker chain was a non-blocker in the port.** The FULL bucket is in room 60
   from the start (`actor_init`: `fcb 60,2,56,144,5`; the original has orig_room 255, X:1647, and it only
   appears after `proxmtbucketrou` X:2985). The player can pick it up without ever visiting room 83, so
   the door (room 84, X:3410) and the knocker (room 89) gate only the now-redundant empty bucket.
4. **(FIXED T0228 in the tape build)** **Daisy was already in the win room.** `actor_init_tape` had daisy1 in room 73 from the start
   (original: orig_room 255, X:1480ff, she only moves there after you reach her in room 94,
   `daisyrou` X:3492). Now daisy1 starts hidden (room 255), Daisy stands in room 94 on the lift (`daisyhere`, riding it as
   `justinlift` X:3530 does) and the meeting (X:3492-3515) moves her: win is impossible without it, as in the original.
5. **(FIXED T0229 in the tape build)** **The crowbar was lying in room 88 from the start**, and Dylan (59) and Doug (88) showed
   Denzil's text. Now the crowbar starts in room 255 (`ORIG_ROOM_LABELS` `crowbarhere`), Doug's first talk shows his 6
   boxes and pokes it into the room (`dougtalking`'s `defw crowbarhere+room`), later talks show `goonmysonmess`; Dylan shows
   his 3 boxes, then `trancemess` on every later talk (talkingtopeople X:2378).

## 1. The solution path, in dependency order (original logic)

Win condition: reach daisy1 in room 73 with `coins == 30` (`daisyrou1` X:3547; coins checked X:3556,
`completedgame` X:3564, ending text `gotallcoins` X:767). Coins are 30 pickups from `cointable` X:504
(pickupcoins X:2154). Start state: room 36, carrying the apple (`resetcarrying` X:5952, apple slot 8),
inventory cap 3 (4 with the bag).

Statuses are for the TAPE build: **IMPL** / **PART** / **MISSING**. Rows are ordered so every row only
depends on earlier rows (several are independent branches; marked).

| # | Room(s) | Item / action (X: lines) | Unlocks | Needs | Tape status |
|---|---|---|---|---|---|
| 1 | 36 | Jug (19) dropped in `proxjug` box (X:3260) -> `fireout` | fire in the dungeon is out (room-2 art removed, `checkfireout` X:5491); the escape route past it | start | **IMPL** `uit_jug` (gameplay.asm `update_item_triggers`) |
| 2 | 36 | Loaf (20) dropped at `proxloaf` X:3344; rat eats it and leaves (`ratrou` X:3292, `thanksforloafmess`) | the rat stops guarding the path | start | **IMPL** `uit_loaf` + rat code (T0033) |
| 3 | 36 | Apple (17) dropped at `proxapple` X:3387 -> `trollgotapplemess`; message hints at the fire/water. Troll block `trollrou` X:3353 launches Dizzy back | hint only in the original; the troll itself is removed by the miner (row 18) | start | **IMPL** `uit_apple` + `update_troll`. Deviation: port also sets `troll_bribed` (the apple lets you past); apple starts on the floor, not in the bag |
| 4 | 36, 52, 35, 51 | Walk out. 36->52 by the open x~208-232 climb (NOTES T0035); 35<->36, 35->51 | entrance hall (52, picture X:3270), moat/portcullis (51) | 1 (fire), 2 | **IMPL** (rooms + `proxpicture` in `tp_fallback`) |
| 5 | 51 | Lever (portswitch X:3208) lowers/raises the portcullis (X:3186); stand under it to pass | east/west traffic around 51/50 | 4 | **IMPL** (base actors, T0076/T0102/T0115) |
| 6 | 68 | **Denzil** (talk, X:695): `denziltalking` pokes `ropehere+room`; he hands over the rope | rope exists in the world | 4 | **IMPL** `give_rope`/`denzil_gave_rope`, `msg_denzil` (T0198/T0199) |
| 7 | 53 | Drop the rope in `proxcroc` box (X:2805) -> crocodile tied (`crocodilerou` X:2747) | cross the gator east | 6 | **IMPL** `cdt_tie` |
| 8 | 45 | **Dozy**: talk 1 = `dozytalking` (X:613; potion appears here), talks 2-4 kick msg, talk 5 `pushdozymess` + float (X:2411, 3234) | sleeping potion (15) in the world | reach 45 | **IMPL** `dozy_talk`, `update_dozy`, T0220 |
| 9 | 54 | Drop potion in `proxsleep` box (X:2733) -> dragon asleep (dragon X:2566) | pass the dragon east to the well room 55 | 7, 8 | **IMPL** `cdt_potion` + `update_dragon` |
| 10 | 88 | **Doug** (talk, X:796): `dougtalking` pokes `crowbarhere+room` (crowbar) | crowbar in the world | reach 88 (lift 88 needs key 3) | **IMPL T0229** crowbar starts hidden; Doug's 6 boxes + poke (`tape_talk`, tape_talk_code.asm; harness/tape_people229.lua) |
| 11 | 55 | Drop crowbar in `proxcrowbar` box (X:3440) -> well lid off | well shaft down to 39 -> 23 -> 22/24 (underground rooms) | 9, 10 | **IMPL** `cdt_crowbar` / `fire_welllid` |
| 12 | 100->50 | Bone (6) from the attic 100; drop for Armorog in 50 (`armorogrou` X:2442, `fedarmorog` X:883) | Armorog stops killing in his den | reach 100 (84 up) | **IMPL** (`update_armorog`, msg_fedarmorog; T0123) |
| 13 | 85, 24, 60, 48 | Keys 1-4 (frame 13). Drop in room 56's hut at the slot box: key1 (76,120)->lift 71, key2 (164,120)->lift 40, key3 (84,160)->lift 88, key4 (156,160)->lift 56 (X:2906-2928 `proxkey1-4`; machines/lifts found by table position) | lifts in 71, 40, 88, 56 run | 11 for key2/3 rooms (24, 60); key 4 needs row 14 | **IMPL** `cdt_key` (4 boxes, T0239) |
| 14 | 48 | Rocks: 3 boulders (rooms 50, 35, 53, frames 138/139/136) dropped in `proxrock` box X:2816 -> `waterheight` +6 each; log (`logrou` X:2831) rises | log reaches the left cliff -> key 4 (frame 13 at 32,96) | 7/4 (rocks in 53/50/35) | **IMPL** `cdt_rock`, `update_log48` (T0216) |
| 15 | 49 | Hawk (`hawkrou` X:2852) kills in the dive zone | coin in 49 | reach 49 | **IMPL** `update_hawk` (T0239) |
| 16 | 40 | Egg: ONLY the room-93 egg (`goldenegghere`, X:1587) carries `proxegg` (X:3456): dropped in the nest box (raw (54,150,4,20)) it sets dragonhere1 var1=255 -> asleep. The nest egg (`goldenegghere1`) has no prox pointer: dropping it does nothing; TAKING it makes `trytostartbreathing` fire (X:2540). Without the 93 egg the head kills on every pass | dragon's lair 40 passable, coin 40; lift 40 (key 2) | 13, **beanstalk -> clouds -> egg in 93 (T0235)** | **IMPL** `update_dragon40`, `cdt_egg` (T0239; T0235 made it 93-egg-only) |
| 17 | 41 | Miner (troll hiding, X:3466): touching box (90,120,2,32) moves `trollhere` to 255, shoves you | troll leaves room 36 (coin 36 zone) | reach 41 | **IMPL** `ut_tab` row 41 |
| 18 | 41 | **Pickaxe** (frame 9, room 87) dropped in `proxpickaxe` box (X:3449) -> `rockhere` room=255 (rock frame 146, a blocker actor) | rock gone; coin 41 area | reach 87, 41 | **IMPL T0226** (rock actor in the tape table, solid, blocks the left ledge; `cdt_pickaxe`, usepickaxemess; harness/tape_items226.lua) |
| 19 | 94 | **Rug** (frame 12, room 40) dropped in `proxrug` box (X:3481) -> carpets cover the two daggers | safe floor in Daisy's prison | reach 40, 94 | **IMPL T0227** (rug drop -> carpets, two tape-table daggers that kill, solid carpets: standing on one is safe; harness/tape_items227.lua) |
| 20 | 22 | **Shopkeeper**: `shopkeepercount` starts 255, counts down only while you are in room 22 (`shopkeeperrou` X:3012); then `shopkeeperappearsmess` and he stands at (68,136). Drop the COW (frame 7, room 58) in `proxshopkeeper` box (66,160,8,16) X:3028 (called from the drop path X:5853) -> `shoptalk` X:577, cow consumed, `beanhere+room` poked = bean in room 22. Any other item -> `givingjunkmess` | **the bean** | 11 (reach 22 via well, row 11) | **IMPL T0223** (records, sprites, `update_shop`, `cdt_shop`, full 8-box `shoptalk`, junk replies; harness/tape_beanstalk.lua) |
| 21 | 83 | Door knocker (frame 21, room 89) dropped in `proxdoor` box (X:3410) -> `doorhere` room=255 | door in 84 opens -> room 83 (empty bucket) | reach 89, 84 | **IMPL T0226** (`cdt_knocker`; walk 84 -> 83 proven with real input, blocked before) |
| 22 | 60 | Empty bucket (frame 5, room 83) dropped at `proxmtbucket` X:2982 -> full bucket appears in 60 | bucket of water | 21 | **IMPL T0226** (`cdt_bucket`; the full bucket now starts in room 255 in the tape build, so 21 -> 83 -> 22 -> 60 is mandatory as in the original) |
| 23 | 58 | Bean dropped in `proxbean` box (71,160,8,16) X:3003 -> [X-ALL.TXT line 870] (bean consumed). Manure (3) is a decoy: `pickupmanure` X:2365 | bean planted in dry manure | 20 | **IMPL T0223** (`cdt_tape` frame 2 in room 58's box; original keeps no planted state) |
| 24 | 58 | Full bucket dropped in the same box, `proxfullbucket` X:2990 -> `manurehere+var1=2`, Dizzy shoved left 10; `checkbeanstalk` X:5478 redraws room 58 as room 1 (beanstalk) | beanstalk: 58 -> 74 -> clouds (75, 91, 92, 93, 94); Dylan hints ("[X-ALL.TXT line 687] [X-ALL.TXT line 688]", X:674) | 22 (or the bucket in 60), 23 | **IMPL T0223** (`cdt_tape` frame 5; room-1 placements appended at load by `tape_room_hook`; 58 -> 74 climbed with real input) |
| 25 | 59 | **Dylan** (talk, X:674): 3 boxes then `trancemess`; no item | flavour/hint | reach 59 | **IMPL T0229** 3 boxes, then `trancemess` (tape_people229.lua) |
| 26 | 56, 87, 52, 55, 59, 72, 73 | "Decoy" items sit exactly on coins: leaves (59 @52,102; 55 @58,136), railing (55 @76,128; 56 @84,128; 72 @76,80; 52 @86,88), window frame (73 @56,72). `pickupablerou` (domoving) takes the pickup key before `pickupcoins` (X:1213), so you must lift/move the decoy first | access to 7 coins | n/a | **IMPL** generic pickup; open item: `coin_covered` ignores tape-table actors (room 73 coin vs window frame, NOTES T0236) |
| 27 | 72/73 | Hole (frame 11, room 72) and whiskey (18, room 53), manure, bag (1, room 55): carrying the hole drops everything (`checkholdinghole` X:2520); dropping the whiskey makes you drunk (`droppingwhiskey` X:5858, `checkifdrunk` X:2947); bag raises cap to 4 | none required (traps/decoys; bag is convenience) | n/a | **IMPL T0230** (bag T0227; hole ON, `tape_hole_check`; whiskey `tape_drop_hook` + `tape_drunk_tick`, 4 tumbles of a 7-step slide; manure message in `tape_take_hook`; 340 B total, NOTES `## T0230`) |
| 28 | 94 | **Daisy** (`daisyrou` X:3492): touching her while standing still (`sequence` 0), tune 3, `gottodaisymess`, heart demo, `daisyrunsmess` (X:729-745), Daisy moves to 73 | daisy1 appears in 73 | clouds | **IMPL T0228** (`ud94_daisy` + `tape_heart_demo`, tape_daisy_code.asm; Daisy rides the lift; tune under both boxes and silent during the demo; harness/tape_daisy94.lua) |
| 29 | 73 | Daisy1 with 30 coins -> tune 3, `gotallcoins`, heart demo, `completedgame` | **win** | all 30 coins | **IMPL** `update_daisy1` + `tape_win_chatter` (T0236/T0221) + the heart demo after the last box (T0228, silent: the 1-bit-DAC mixer cannot share the CPU with it) |

Ordering note: rows 1-17 and the coin pickups can be done in many orders; the strict chains are
(6->7), (8->9), (10->11), (13: keys->lifts), (20->23->24), and (24 -> clouds).

## 2. The 30 coins (X:504; port tables `coin_data*.asm` hold all 30 per NOTES T0236)

Coin = room, raw (x,y) -> pixel (x,y). "Gate" = steps from section 1 that must precede it, per the
original's trigger logic (GUESS where the map/art route was not walked; marked ?).

| # | Room | raw -> px | Gate |
|---|---|---|---|
| 12 | 36 | (82,160) -> (200,160) | in the troll's launch zone (X:3359 box 82..90): needs the troll gone (row 17 miner) or, in the port, the apple (row 3) |
| 29 | 52 | (86,88) -> (216,88) | row 4; railing decoy on top of it (row 26) |
| 22 | 51 | (88,152) -> (224,152) | rows 4-5 |
| 15 | 67 | (62,112) -> (120,112) | row 4 ? (west wing, 51+16) |
| 16 | 68 | (84,112) -> (208,112) | row 4 ? (banquet hall, 52+16) |
| 17 | 69 | (40,160) -> (32,160) | row 4 ?; dagger trap in 69 (implemented) |
| 23 | 84 | (60,96) -> (112,96) | row 4 ? (castle staircase, 68+16); door (21) not needed |
| 24 | 87 | (84,160) -> (208,160) | row 4 ? |
| 7 | 86 | (82,152) -> (200,152) | row 4 ? (longjump cloud, off 85/87) |
| 19 | 89 | (58,96) -> (104,96) | reach 89 via 88 -> lift 88 (key 3, row 13) ? |
| 18 | 56 | (84,128) -> (208,128) | row 9 or 11; railing decoy |
| 4, 5 | 55 | (58,136) (76,128) -> px (104,136) (176,128) | row 9 (dragon asleep); both under decoys (leaves, railing) |
| 3 | 59 | (52,102) -> (80,102) | row 9 route ?; leaves decoy |
| 25 | 57 | (72,160) -> (160,160) | row 9 route ? |
| 28 | 72 | (76,80) -> (176,80) | row 9 route ?; railing decoy |
| 6 | 73 | (56,72) -> (96,72) | row 9 route ?; window-frame decoy |
| 27 | 40 | (50,72) -> (72,72) | row 16 (egg in nest) |
| 10 | 41 | (44,64) -> (48,64) | row 17 shove is east edge; rock (row 18) absent in port |
| 21 | 49 | (62,160) -> (120,160) | row 15 hawk |
| 9 | 22 | (36,104) -> (16,104) | row 11 (well -> 39 -> 23 -> 22) ? |
| 8 | 24 | (44,160) -> (48,160) | row 11 ? |
| 2 | 31 | (38,120) -> (24,120) | row 11 ? (south of 47) |
| 13 | 46 | (86,128) -> (216,128) | row 11 ? (docks) |
| 1 | 63 | (58,152) -> (104,152) | crafty cloud (47+16): from 47 ledge (88,104) jump right onto the roof cap (152,72), jump up (T0232, jumptrace-verified; bot pending) |
| 30 | 76 | (70,64) -> (152,64) | ? volcano (60+16) |
| 11 | 77 | (54,112) -> (88,112) | ? active volcano; lava kills |
| 26 | 75 | (56,88) -> (96,88) | **rows 20-24 (beanstalk)**: 75 is above 59, east of 74 |
| 14 | 92 | (68,88) -> (144,88) | **rows 20-24** via 74/75/91 (cloud rooms) ? |
| 20 | 94 | (60,152) -> (112,152) | clouds (93 -> 94); NOTES T0239 reached it by warp, route from start untraced |

Coins that only the beanstalk chain (rows 20, 23, 24) reaches: **75, 92, 94**. If the volcano slope
(76 -> 77 -> 93) is a second route to the cloud castle (the ZX map image suggests the hill climbs
toward it) then only **75 and 92** are strictly beanstalk-gated; I could not confirm that from data
(GUESS). Coin 63's route: the roof cap of 47 (T0232, measured on the original and in the port). Coin 31 (The Amazing Illusion) is a one-way pocket in the original: OPEN.

## 3. Tape build status summary

IMPLEMENTED: rows 1-2, 4-17 (10 in T0229), 20, 23, 24, 25 (T0229), 28, 29; coins 30/30 present in the tables; lifts/keys; Dozy; Denzil; armorog;
log/rocks; hawk; miner; egg/dragon 40; picture; ending text + tune.
PARTIAL: row 3 (apple bribes). (Row 28, Daisy, IMPLEMENTED in T0228; rows 10 and 25, Doug/Dylan, IMPLEMENTED in T0229.)
MISSING and BLOCKING: none left after T0223 (rows 20, 23, 24 are IMPLEMENTED; the chain 22 -> 58 -> 74 is verified by harness/tape_beanstalk.lua).
MISSING, non-blocking (fidelity only): none of rows 18-27 remain (row 27 completed in T0230; rows 18, 21, 22 in T0226, row 19 and the bag in T0227).

## 4. Cost of the missing steps (bytes in the tape build)

Message estimate = 0.71 * chars + 2 + lines (calibrated: `msg_puteggback` 52 B measured, formula 52;
`msg_rockinwater` 59 B, formula 60). Code estimate for a box-test trigger = ~42 B counted from
`cdt_egg` source (lda/cmpa/lbne + 4 box constants + `aabb_test` + effect + `msg_begin/ldx/msg_box_done`)
+ ~5 B dispatch `cmpa/lbeq` in `check_drop_trigger`. `cdt_rock` = 124 B incl. message (given).
Records: 8 B live + 8 B template (actor_init_tape + _template) = 16 B each. Sprites: bpr*h+3.

### 4a. Blocking set (needed to complete the game via the beanstalk)

| Piece | Parts | Bytes | Label |
|---|---|---|---|
| Bean item | record 16, sprite frame 2 (16x16) 35 | 51 | MEASURED |
| Shopkeeper | 2 records 32, sprite frame 105 (16x39) 81 | 113 | MEASURED |
| Shopkeeper appears (count 255 ticks in room 22, redraw) | timer + hook ~35, `shopkeeperappearsmess` ~41 | ~76 | GUESS |
| Trade on drop (cow frame 7 in box, consume cow, poke bean room; junk reply otherwise) | code ~70, trade stream minimal (cow + bean boxes, 146 chars) ~116, junk msgs ~59 | ~245 (full original stream 230 instead of 116 -> ~359) | GUESS |
| `proxbean` (plant) | trigger 42+5, `plantbeanmess` 65 | ~112 | GUESS |
| `proxfullbucket` (water) | trigger 42+5 + shove/flag ~10, `throwwateronbeanmess` 96 | ~153 | GUESS |
| Beanstalk overlay (room 1, X:5478) | 12 placements 44 B raw (frames 224-227 already exist for room 74), draw + collision/climb hook ~100 | ~145 | data MEASURED, code GUESS |
| **Blocking total** | | **~795 (min) / ~910 (full shoptalk)** | GUESS |

Sharing the box test between plant and water (same box 71,160,8,16) saves ~40 -> ~755 min.
Free space: tape-low 496 + low2 41 + tape-only 226 = **763** (title-hole 597 is load-time, not
usable for runtime code). So the minimal blocking set is borderline; it fits only with shortened
messages (top-tier text decision) or by finding another ~100-150 B. Code must not go in region2
(data-sized, 41 B free).

### 4b. Non-blocking (fidelity) set, for reference

| Piece | Bytes | Label |
|---|---|---|
| Door knocker `proxdoor` (hide door actor, `usedoorknockermess` 41) | ~100 | GUESS |
| Empty bucket fill `proxmtbucket` (+ port must set full-bucket orig room 255: 0 B) | ~80 | GUESS |
| Pickaxe + rock actor (record 16, sprite 146 24x23 = 72, trigger 47, msg 32) | ~167 | GUESS |
| Rug + room-94 daggers/carpets (4 records 64, carpet sprite 35, table-driven `update_dagger` ~40, trigger 47, msg 42) | ~230 | GUESS |
| Daisy in room 94 + the heart demo (T0228, MEASURED 940 B: records 16, sprites 129, messages 173, meeting/lift code 107, demo code 489, resident hooks 13, tune hooks 10, +3 update_switch1) | 940 | measured |
| Dylan + Doug talk text and dispatch (T0229, MEASURED: Dylan 161 + trancemess 44 + Doug 376 + goonmysonmess 54 text, 59 code, 6 reset) | 700 | measured |
| Bag / drunk whiskey / hole-drops-all / manure msg | ~20 / ~105 / ~60 / ~58 | GUESS |

## 5. Verdict

### T0223 status (supersedes the verdict below for the blocking chain)

**The beanstalk chain is built and verified; the "cannot be completed" blocker is removed.** The
tape build now has the shopkeeper (appears after the original's 255-pass delay in room 22, both
halves, mirrored second half), the full 8-box cow bargaining stream (token-identical to X:577) that
leaves the bean (frame 2) in room 22, the junk replies (every 4th = stopgivingjunk), `proxbean`
(plant, "unable to grow", bean consumed), `proxfullbucket` (water: bucket consumed, Dizzy shoved
40 px left, stalk grows, 12 room-1 placements drawn over room 58 and added to its collision mask),
and room 58 -> 74 is climbed with REAL jump input (4 steps, the same input script does NOT reach 74
without the stalk). Verified by `tools/verify_beanstalk.sh` (harness/tape_beanstalk.lua 50 PASS /
0 FAIL, the offline-derived stalk mask matches byte for byte, real XRoar tape boot of the new
TAPE_LOW_REGION3). NOT verified: the walk from room 74 on through the cloud rooms (75, 91, 92, 93,
94) to coins 75/92/94 -- room 74 is reached, nothing past it was driven. The full bucket is still
pre-placed in room 60 (the empty-bucket/door/knocker chain stays a non-blocker, rows 21-22).
What still stops a full completion, if anything, is therefore the 74 -> clouds -> coins leg and the
other coin gates in section 2, not the beanstalk. Free tape space is now ~152 B across all four
regions (see NOTES.md T0223): the remaining MISSING fidelity items (section 4b) will not fit without
new space.

### Original verdict (2026-10-02, before T0223; kept for the record)

**The tape build cannot be completed today.** The first step a player hits that cannot be done is the
beanstalk chain: nothing in room 22 ever produces a bean (no shopkeeper, no bean), and even with a bean
there is no plant/water trigger and no beanstalk, so room 58 -> 74 is closed. Coins that become
unreachable if the cloud rooms are only reachable by the stalk: **75, 92, 94** (3 coins; 63/76/77 are
unresolved GUESSes depending on the volcano/crafty-cloud routes). With <30 coins `daisyrou1` plays the
nag text and never ends the game. Everything else on the original's critical path (fire, rat, rope,
gator, potion, dragon, crowbar/well, keys/lifts, rocks/log, hawk, miner, egg, Dozy, Denzil, coins table,
ending) is implemented. Door/knocker, bucket fill, pickaxe, rug and the Daisy meeting are missing but
do not block (the port pre-places the full bucket and omits the obstacles they remove).

Open verification (not done here, cheap to do before building): walk/warp whether any route reaches 93/94
from the volcano (rooms 60 -> 76 -> 77) without the stalk. If yes, only coins 75 and 92 need the stalk.

Tool: `tools/solution_audit.py` (python3, read-only). Verify: `python3 tools/solution_audit.py`
exits 0 and prints the message/sprite/coin tables used above.
