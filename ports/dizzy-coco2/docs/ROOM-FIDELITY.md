# Room-by-room fidelity of the CoCo port against the ZX Spectrum original (T0255)

## Summary (current as of T0262, 2026-10-25)

**Question:** does every moving thing in every room of the CoCo port behave as it does in the Spectrum original (position,
frame, mirror, timing, where Dizzy dies)? **Answer:** yes for 48 of the 49 rooms the two playthrough bots enter (rooms 22..100
of the tape build; room 70 is never entered by either route and holds no actor), up to the items below. Measured with
`tools/roomcmp` and `tools/hazardcmp` (reports in `target/roomcmp/`, gitignored: derived from your own tape), re-run end to end
by `tools/verify_roomcmp255.sh` (last line `VERIFY_ROOMCMP255 PASS`).

* **Fixed (F1..F13)**: differences found and corrected, then re-measured equal. Flame/water counters on room entry (F1), rat
  pace and legs (F2), dragon breath-before-swing (F4) and per-dragon swing counter (F5), the log's step on entry (F6), levers
  drawn mirrored once thrown (F7), Daisy's flip (F8), room 94's lift/lever/Daisy pace (F9), the coin tune (F10), the actor reset
  after every message box (F11), the original's pickup priority (F12), the footstep thud (F13). (The numbering skips F3; there is no F3 entry.)
* **Expected (E1..E7)**: differences kept on purpose, each named with its reason in `tools/roomcmp/expectations.toml`. Rat
  start position and mirror (E1, E2); the water tile at x=-16 px in rooms 45 and 46 (E3); two random generators (E4); the miner
  parked off-screen until his trigger (E5); room 84's knock chatter depends on where the bots stand (E6); art placed at negative
  x is drawn by the FLOPPY build only (E7).
* **Decided (D1..D4)**, user-approved: D1 box-close actor reset = F11, D2 pickup order = F12, D3 footstep thud = F13, D4 left-edge
  art = floppy build only (E7).
* **Open**: **D5** the port's kill box is 7 px taller than the original's (task T0238, a user decision; it makes the portcullis
  crossing in room 51 tighter); **T0239** the death-animation countdown and the drunk timer still run on Dizzy's clock, not the
  4/3 actor clock; the three dialogue segments that differ (24, 70, 73) are the bots' own differences, not the game's; E3 would
  need a runtime left clip or a per-tile frame set. Nothing here has been tested on real hardware.
* **Not covered**: sound waveforms (the ZX is AY, the port a 1-bit DAC; only the triggers are compared), pixels of the art
  (checked separately: collision masks 19/19, ZX screenshots for the clipped rooms), and rooms the bots never enter.

How the numbers were made: both bots (`tools/playthrough.sh`, `tools/zx_playthrough.sh`, the same 106-segment plan) save a
MAME state at the **first entry into every room** (`PT_ENTRY_SAVE=1`); each state is loaded on its own machine and run
400 actor ticks with **no key pressed**, recording every actor record of the room (ZX `movingdata`, port `actor_ram` /
`actor_init_tape`), flame/water counters and tables, and message boxes; the two traces are compared per actor and channel
(room, x, y, frame, colour/mirror) with a phase search. A second comparison (`roomcmp visits`) reads the **passive logs of the
whole bot runs** and compares every actor's behaviour phase-free (run lengths of each channel), the order of printed
original strings per segment, and Dizzy's animation table. Actor tick = one run of the original's main loop = 4/3 of a Dizzy
update (the port's `actors_pass`, T0237).

Verdict key: **MATCH** equal tick for tick (up to the 0..2 tick save-point jitter), **FIXED** differed, fixed in T0255 and
re-measured equal, **EXPECTED** differs for a reason named in `tools/roomcmp/expectations.toml`, **DECISION** needs the coordinator
(section D).

Section D holds only D5 now (D1..D4 are decided, see the summary).

## Per-room table

| Room | Title | Actors (original routines) | Verdict | Deviations |
|---|---|---|---|---|
| 22 | The Market Square | none | MATCH | box timing equal (tick 254 on both) |
| 23 | A Strange New World | none | MATCH | |
| 24 | Inside the Church | 1 flame | MATCH | flame counter FIXED (F1) |
| 31 | The Amazing Illusion | none | MATCH | |
| 35 | Smuggler's Hideout | 1 flame, 3 water | MATCH | counters FIXED (F1) |
| 36 | The Castle's Dungeon | rat, troll, 6 flames (fire pit) | FIXED + EXPECTED | rat pace and legs FIXED (F2); rat start x and mirror EXPECTED (E1, E2); troll MATCH |
| 39 | Going Down The Well | none | MATCH | |
| 40 | The Dragon's Lair | dragon, lift | FIXED | dragon swing counter now per dragon (F5); breath order (F4); lift MATCH |
| 41 | The Deserted Mines | miner, rock-box | MATCH (EXPECTED repr.) | the miner is parked in room 255 until his trigger (T0239, x=96 units is off-screen); same trigger and shove, covered by harness/tape_miner.lua (E5) |
| 45 | Looking Out To Sea | Dozy's float, 8 water | EXPECTED | leftmost water tile at x=-16 px cannot be drawn (E3) |
| 46 | The Docks And Pier | 4 water | EXPECTED | same (E3) |
| 47 | Fourway Warehouse | none | MATCH | |
| 48 | The Broken Bridge | log, 3 water | FIXED | log took no step on room entry (F6) |
| 49 | The Guard House | hawk | MATCH | x/frame sequence equal; box-close reset FIXED (F11) |
| 50 | Armorog's Den | Armorog | MATCH | wake-up/run/den sequence equal (82 runs); box-close reset FIXED (F11) |
| 51 | Moat And Portcullis | portcullis, lever | FIXED | lever drawn mirrored once thrown (F7); gate MATCH (411 runs equal) |
| 52 | The Entrance Hall | 4 flames | MATCH | |
| 53 | The Snap Happy Gator | gator, 1 flame, 3 water | MATCH | jaws 123/124 sequence equal |
| 54 | The Wide-Eyed Dragon | dragon | MATCH (random) | breath start is a random roll (E4); order of roll/swing FIXED (F4) |
| 55 | The Bottomless Well | well lid | MATCH | |
| 56 | The Lift Control Hut | lift, 4 machines | MATCH | machines mirrored when keyed (T0124) |
| 57..60 | Base Of Tree House, The Smelly Allotment, The Large Oak Tree, Base Of The Volcano | none (60: 1 water) | MATCH | |
| 63 | The Crafty Cloud | none | MATCH | |
| 67 | The West Wing | 1 flame | MATCH | |
| 68 | The Banquet Hall | 6 flames | MATCH | |
| 69 | The East Wing | dagger, 4 flames | MATCH | |
| 70 | Empty sky | none | not entered by either route | no actor |
| 71 | Keep Out! Dozy's Hut | lift | MATCH | |
| 72 | Denzil's Pad | 2 flames | MATCH | |
| 73 | Daisy's Empty Hut | Daisy (second) | FIXED | Daisy flips every second tick (F8) |
| 74..76 | The Giant Beanstalk, Complex Cloud Route, Near The Volcano Top | none | MATCH | |
| 77 | The Active Volcano | 8 water | MATCH | |
| 83 | The West Tower | 1 flame | MATCH | |
| 84 | The Castle Staircase | door, 2 flames | MATCH | knock box trigger verified in the port (E6) |
| 85 | The East Tower | 1 flame | MATCH | |
| 86, 87 | The Longjump Cloud, The Meeting Hall | none | MATCH | |
| 88 | Lift To The Elders | lift, 3 flames | MATCH | |
| 89 | Dizzy's Parents Hut | none | MATCH | |
| 91, 92 | Yet More Clouds, More 'Orrible Clouds | none | MATCH | |
| 93 | The Cloud Castle | 1 flame | MATCH | |
| 94 | Daisy's Prison | 2 daggers, Daisy, lift, lever, 2 flames | FIXED | lift/Daisy/lever run on every second tick (F9); Daisy flip (F8); lever mirror (F7) |
| 100 | The Attic | none | MATCH | |

## FIXED in T0255 (all measured equal afterwards)

* F1 flame/water counters: the original's `addtoflame`/`addtowater` start every room's flames at counter 0 and its water at 3;
  the port's global counters carried over from the last room (phase offsets of up to 7 ticks on entry). `load_room` now resets them.
* F2 rat: `delay` 2 (runs on every second tick) and the 60-run first leg were ignored: the port rat moved twice as fast and its
  legs took half the time. Now 4 px per 2 ticks, legs counted in runs (16..31), first leg 60 runs. (Bot: the loaf is dropped at
  the ZX bot's spot, 72 px, instead of the edge of the patrol, which the slower rat almost never reached.)
* F4 dragon breath: `dragonrou` rolls `trytostartbreathing` BEFORE the swing, and a breath that starts keeps the swing, draws
  the breath head frame and runs the first flame step in the same tick; the port rolled after the head, one tick late.
* F5 the swing counter (`delaycounter`) is per dragon in the original; the port had one shared by rooms 54 and 40
  (visible as a swing phase offset in the lair, now equal).
* F6 `resetlog` is the log's step: every entry into room 48 runs one, so the log's cycle is one step ahead of its beat.
* F7 levers (rooms 51 and 94): `resetmachines` copies var1 into colour bit 7 = the lever is drawn mirrored once thrown / while stood on.
* F8 Daisy (rooms 94 and 73): `anidaisy` flips her colour bit 7 on every run (every second tick): she is drawn mirrored on alternate runs.
* F9 room 94: the lift, the lever and Daisy have `delay` 2; the port ran them every tick (lift twice as fast). T0262: harness/lift94.lua never measured speed; it now asserts
  1.3..1.7 mainloop passes per px while the lift is active (ideal 1.5 = delay 2 at 4 ticks per 3 passes, measured 1.43; the old pace would be 0.75).
* F10 sound: tune 5 is the COIN tune (`pickupcoins`); the port played it on every item pickup and not on coins. Moved.
* F11 (was D1, T0258) box-close reset. X-ALL `windowrou1` / `justexitinvent` -> `resetuproom` -> `roomsetup` (5436) runs `resetroommoving` (1859) for
  every record of the room: Armorog (`resetarmorog` 2436: back to sleep unless fed), the hawk (`resethawk` 2848: y=52, dive off, one animation step, delay
  counter untouched), the log (`resetlog`: one step), the dragon (`breathingfire` := 0, also at every room entry), and `addtoflame`/`addtowater` restart the
  flame and water counters (0 and 3). The port: `box_reset` (room36.asm; load_room calls it too) = dragon_fire := 0, flame/water counters, `inc room_load_seq`
  (the actors that keep state reset themselves on a change of that byte). Called at the end of msg_box_done, once at the end of a msg_chatter run, after the two
  troll boxes, Daisy's win box and at both exits of the inventory (before the drop trigger, as `justexitinvent`); not after the death box (nextlife re-enters the
  room anyway) and not after the port's own save/load boxes. Verifier: harness/tape_boxreset.lua.
* F12 (was D2, T0259) pickup priority. `domoving` walks `movingdata` from the LAST record down and the first pickupable overlapping Dizzy takes the key; the
  coins come after (`pickupcoins`). roompack now stores each pickupable's movingdata index in byte 6 of its record (both tables); try_pickup scans both tables,
  keeps the highest index, then tries the coins, then the picture / inventory. Doug no longer beats the crowbar he makes appear; Dozy beats the potion (as on the ZX: the
  potion's presses talk to him until the 5th floats him away); the loaf beats the jug. Verifier: harness/tape_pickuporder.lua (cross-table both ways). The CoCo bot
  route needed two edits to follow the same order (seg 24 and the coin under the window frame in seg 68).
* F13 (was D3, T0260) walking thud. `updatedizzy` plays sndfx 0 (thud) on animation frames 1 and 5 and sndfx 1 (tap) on 3 and 7, i.e. on every odd frame. The port plays
  both; the thud (captured from the original's AY data, 54 Hz) is capped to ONE half-wave (~9 ms): the uncapped 2 half-waves (19 ms) cost one mainloop pass in 13
  while walking, the capped one costs nothing measurable (52 px / 13 passes in 60 frames and 72 / 19 in 100, with and without the thud). Verifier: harness/footsteps.lua
  (taps on fx0/fx1, DAC write bursts == taps + thuds, nothing in the air; NOTHUD=1 for the speed A/B).

## EXPECTED

* E1 rat start: the original resets the rat to x=96 units = 256 px (just off the right edge) at game start; a port x is one
  byte, so it starts at 40 px on its patrol. Patrol 48..192, pace and leg lengths equal; the random legs differ (two RNGs).
* E2 rat mirror: the original flips colour bit 7 on each turn; the port keeps the facing in v1 and draws the mirrored sprite: same picture.
* E3 water tile at x=-16 px (rooms 45, 46): not representable (one unsigned byte, no left clipping in blit); the left 16 px strip
  has no water and no drowning box, and a wrapped duplicate sits at 240. The tile is a water-list entry (32 px wide, 16 visible) drawn with one shared
  frame set, so even the converter clip of D4 does not reach it; needs a runtime left clip or a per-tile cropped frame set (design).
* E7 art placed at negative x (20 placements in rooms 23, 40, 45, 48, 51, 55, 56, 58, 60, 84, 94; every one partly visible): the FLOPPY build draws the
  visible columns (T0261: `floppy_leftclip.asm`, cropped at room load into a scratch buffer and inserted into the sorted placement list; verified against ZX
  screenshots of rooms 45, 51, 55, 60). The TAPE and -run builds do NOT (roompack drops them: one unsigned x byte, no left clip in `blit`, no memory for stored
  cropped bitmaps), so the left 4..36 px of those objects are missing there. Collision is unaffected in every build (masks include them; cmask 19/19 on both).
* E4 random events (the dragon's 5/256 breath roll per tick, the rat's leg lengths): the rules are equal, the two RNGs differ.
* E5 the miner is parked in room 255 until his trigger (x=96 units is off-screen in the original too).
* E6 room 84 knock chatter: both machines show it the first time Dizzy STANDS in the knock box; the two bots stand at different
  places before the knocker is dropped (the port's trigger works: poked Dizzy to (16,176) -> box at once).

## D. For decision (coordinator)

D1, D2 and D3 are FIXED (F11, F12, F13 above); D4 is decided (E7).

* **D4 Art placed at negative x**: DECIDED (T0261): FLOPPY build only, see E7. Tape and -run builds keep the difference (E7).
* **D5 Kill box height** (open since T0238): `actor_hit` kills with a box 7 px taller than `collidewithdizzy16`.

## Dialogue, animation, sound

* Dialogue identity: `roomcmp visits` taps the first byte of every original string the ZX prints and of every message stream of
  the port, keys them by the original's source line, and compares the sequence of strings printed in each of the 106 segments
  (box runs; strings read outside a box are ignored). **103 of 106 segments print the same strings in the same order**; the three
  that differ are the bots' own differences: seg 24 (the port bot talks to Dozy once more), seg 70 (the ZX bot stands in the knock box, E6),
  seg 73 (the ZX bot's drop overlaps the manure). Seg 53 (the port bot's crowbar press hit Doug again) became equal with F12.
  Box geometry, line breaks and text bytes: `tools/roompack/target/release/verify_tape_text` (every tape-only stream equals the
  original's), the base streams by the `textsplit` fill (keys, no transforms).
* Dizzy's animation: 56 (sequence, counter) combinations seen on both machines show the same frame.
* Actor frames (record `frame` channel): hawk wings 97/98/99, gator jaws 123/124, dragon head 109/110 equal tick for tick.
  Flames: counter 16 steps, mirror on bit 1, equal phase since F1; water: counter 4 steps, frames 92..95. Coins do not animate.
* Sound triggers (X-ALL `sndfx` / `starttune` sites against the port's `play_*`): box open (6) at every box, jump (21), footstep
  (1 tap + 0 thud on alternate odd animation frames; F13), landing none, death (25 + tune 2 after the box), breath (10), drop (11), new life (tune 1), coin (tune 5; F10), Daisy meeting
  and win (tune 3). The ZX audio is AY, the port's is the 1-bit DAC; only the triggers are comparable.

## Where Dizzy dies (hazard boxes), `tools/hazardcmp.sh`

Dizzy is put on a grid of positions in each room (x 16..212 step 4, feet y 78..176 step 2) on both machines and the machine's own
`killed` write says whether anything kills him there. Rooms with only static hazards give the SAME kill map up to one-pixel edge
noise (the port's idle blink changes his box by a pixel): flames 24, 60, 67..69, 71..73, 83..85, 93; water 35, 45, 46, 48, 60, 77; gate 51;
daggers/lift cogs 94. Rooms with moving killers (36 rat, 40 and 54 dragon, 49 hawk, 50 Armorog, 53 gator, 88 lift) differ by the
phase of the killer at the moment of the probe; the dragon's flames in 54 only exist where the ZX's random breath happened to be on.
Not a difference of the hazard.

## Next

Pending at the time of writing: D5 and T0239 (see the summary); the scenario checks for triggered one-shots that no bot step exercises while
standing still (troll shove, miner, Dozy float, dagger kill) rely on their own harnesses (tape_miner, actorlife, dozyfloat).
