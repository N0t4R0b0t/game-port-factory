# Fantasy World Dizzy (CoCo 2) — start-to-finish playtest guide

**Aim:** play the tape build from boot to the winning screen, and note anything that differs from
what this guide says should happen. All of the original's content is now in the tape build.

## Before you start

```bash
cd ports/dizzy-coco2
./play.sh --tape --inf-lives
```

- `--tape` builds `target/room36.cas` and boots it the real way, with one `CLOADM` and `EXEC`. XRoar
  types those for you.
- XRoar's fast tape loading is on. To time a real-speed load, run
  `./play.sh --tape --inf-lives -- -no-tape-fast`.
- `--inf-lives` means a death still shows its message and the death tune, then respawns you, but
  never costs a life. **Infinite lives is NOT in a plain `./play.sh` build.** A later run without
  the flag rebuilds a normal game.
- If something goes wrong in a room and you want to report exactly where, start with `PLAY_GDB=1`
  and run `python3 tools/coords.py` in another terminal. It prints the room number and Dizzy's x/y.

**Controls:**

| Key | Action |
|---|---|
| Left / Right | walk |
| Up | jump |
| Down | pick up, drop, talk, or open the inventory |
| SPACE | dismiss a message, choose in the inventory |
| Joystick X (right stick) | walk -- see below |
| Joystick fire button | jump; also dismisses a message / chooses in the inventory |

**Joystick (tape build only, `./play.sh --tape`):** the CoCo's analog **right** joystick works at the same time as
the keyboard. Under XRoar attach one to the right port: `./play.sh --tape -- -joy-right mjoy0` (the mouse: move it
left/right, left button = fire) or `-joy-right kjoy0` (cursor keys + Alt_L as the stick); a real gamepad is
configured as an XRoar joystick profile (`xroar -joy help`, `-joy NAME -joy-axis 0=0,0 -joy-button 0=0,0`, then
`-joy-right NAME`). The stick can only be **slower** than the keys, never faster: pushed all the way = the keyboard's
speed (one 4 px step every update); a partial push walks at 3/4, 1/2 or 1/4 of that; the middle quarter of the
travel is a dead zone (cheap CoCo pots drift) where Dizzy stands still. Fire jumps; a jump with the stick pushed
(any amount past the dead zone) goes sideways at full speed, with the stick centred it goes straight up. Keep the
stick **centred when the game starts**: a stick that never rests in the dead zone (nothing plugged in reads
pegged) is ignored so a keyboard-only player is never walked off by a floating port. The run build (`./play.sh`
without `--tape`) has no joystick code.

**Floppy build (`./play.sh --floppy`): quick save.** Boots `target/dizzy.dsk` with Disk BASIC (`LOADM"DIZZY":EXEC`,
about 14 s to the title, most of it the loader reading 168 sectors). On the floppy build two more keys work **during
normal play** (standing on the floor, no message box open):

| Key | Action |
|---|---|
| **S** | **save** the game to the one slot (`DIZZY.SAV` on the disk). About 3 s; a box says **GAME SAVED**. |
| **L** | **load** it: the room, items, coins, lives, puzzles solved, enemy and lift states and Dizzy's position come back exactly as saved. About 3 s; a box says **GAME LOADED**, then you play on from there. |

Both ignore the key while you are jumping or falling, dead, in the well, thrown by the troll or at the end; in a message
box or the inventory they simply do not run (press SPACE first). Short boxes tell you what went wrong: **NO SAVED GAME**
(the slot is empty), **SAVE IS FROM ANOTHER VERSION** (the save was made by a different build of the game: a rebuild
makes old saves unusable, on purpose), **DISK ERROR** (no disk, write-protected disk, unreadable or damaged slot). The
game carries on after any of them. There is ONE slot: S overwrites it. In XRoar the disk is attached write-back, so the
save is in `target/dizzy.dsk` once XRoar exits normally (and a rebuild with `tools/floppy_pack.sh` makes a fresh, empty
disk). **Please test:** save in several rooms (early, after a few puzzles, near the end), play on, die, load, and check
that nothing "re-happens" (a door shut again, a coin back, an item duplicated, an enemy in a different place).

**Jumps are committed (as in the original):** after take-off Dizzy ignores the keys until his 8-step jump
animation has wrapped. A jump that lands *between* those steps (for instance up onto the table in 68, which
is 28 px higher) therefore keeps **sliding in the direction of the jump** after landing, with the jump pose,
before he stops (T0236: 7 steps = 28 px for that jump, measured on the ZX original). That is faithful, not a
bug -- report it only if the slide is *longer than 7 steps* or happens after a plain walk. There is no air
control either (user decision: faithful).

**Pace.** Everything that is not Dizzy (lifts, the gate, the gator, the hawk, the rat, the dragons, flames, water, the
shopkeeper's timer) runs 4 ticks per 3 Dizzy updates, as on the Spectrum (T0237). Room 94 is the slowest to draw
(about 11 passes a second against 15 elsewhere). The death animation and the drunk timer are still on Dizzy's clock
(open item T0239).

**Sound.** Walking makes a thud on animation frames 1 and 5 and a tap on 3 and 7 (T0260); none in the air. A coin plays
its own tune; item pickups do not.

**Picking things up.** DOWN takes whatever Dizzy overlaps. When several things overlap, the original's order applies
(T0259): the item that comes *last* in the original's actor list wins, and coins come after every item. In practice:
Dozy beats the potion he makes, the loaf beats the jug, Doug does not beat the crowbar he makes appear, and a coin
under a railing / leaves / window frame needs the item lifted first (one press for the item, another for the coin).

**Boxes reset actors.** Closing any message box (or leaving the inventory) runs the original's room-setup reset
(T0258): Armorog goes back to sleep unless fed, the hawk returns to its patrol height, the log takes one step, the
dragon's breath stops, flame and water animations restart. It is the original's behaviour; do not report it.

You can carry **3 items, or 4 once you have the bag** (the bag is taken, not carried). A 4th pickup puts the oldest
item down in the room. To **use** an item, stand where it is needed, press **DOWN** and choose it in the inventory
(SPACE) to drop it there. To **talk** to someone, walk up to them and press DOWN. Pressing DOWN twice in a row too
quickly is swallowed (the original's debounce, about 7.5 Dizzy updates).

Every room shows its name in the banner. Room numbers are in brackets below so `coords.py` can
confirm where you are. Map rule: going **up** a screen adds 16 to the room number, left/right
subtract/add 1.

**What to note:** for each step, write a tick or a cross plus one line. Especially note:

- anything that freezes or crashes;
- graphics left behind by a moving thing (a "trail");
- a message box that needs SPACE **twice** to close;
- an item that won't drop where this guide says;
- an inventory item with the wrong name;
- anywhere you get stuck in the scenery.

**Known differences from the original** (don't report these; the full list is `docs/ROOM-FIDELITY.md`):

- **Apple:** it lies on the floor in the dungeon instead of starting in your pocket. Giving it to
  the troll also lets you past him.
- **Heart demo:** it plays in **silence**. The music plays under the message boxes before and after
  it, but the CoCo can't run the music and animate the hearts at once.
- **Art at negative x:** 20 scenery pieces at the left edge of rooms 23, 40, 45, 48, 51, 55, 56, 58, 60, 84 and 94 are
  partly off-screen in the original. The FLOPPY build draws the visible part; the TAPE build does not (no memory), so the
  left 4..36 px of those objects are missing there. Collision is the same in both (E7).
- **Water tile at the left edge of rooms 45 and 46:** the leftmost 16 px strip has no water and no drowning box (E3).
- **Random events** (the dragon's breath roll, the rat's leg lengths) follow the original's rules with a different random
  generator (E4). The rat starts on its patrol, not just off-screen (E1).
- **Kill box height:** the port kills with a box 7 px taller than the original's, so the portcullis crossing in 51 has less
  slack than on the Spectrum (open item T0238, user decision).

---

## The route

The steps below are in **the order the playthrough bot plays them** (`harness/playthrough_route.lua`, one 106-segment plan
shared with the Spectrum bot). That order is forced by the original: the lair dragon (step 34) can only be put to sleep
with the golden egg from the Cloud Castle, so the lair is entered twice. "Seg" numbers are the bot's segments 1..106 as
printed in its log; the coin counter after each part is what the bot reaches. You may play in any order that the game
allows (see `docs/SOLUTION-PATH.md` for the dependencies); this one is known to work.

## Part 1 — The dungeon and the castle (seg 1-18, coins 0 -> 6)

1. **Boot.** The title screen appears with music. Press SPACE.
   - **Check:** the game starts in *The Castle's Dungeon* (36), with lives and 0 coins shown.
2. **Fire (36).** Pick up the **jug of water** and drop it at the fire.
   - **Check:** the fire goes out and stays out.
3. **Troll and loaf (36).** Pick up the **apple** and drop it by the troll (floor, x about 164..172).
   - **Check:** he takes it and lets you past. The **loaf** lies where you collect the apple, so you will be holding it too.
4. **Out of the dungeon.** You can **not** climb out from the dungeon floor: the slab at y=80..102 is solid across the whole
   width. With the fire out go **left** to *The Smuggler's Hideout* (35), climb onto its right pillar (y=80) and leave
   **right**: you arrive on the dungeon's **shelf** (y=80, x=8).
5. **Rat (36 shelf).** The rat patrols the shelf (x 48..192, 4 px per 2 actor ticks). Drop the **loaf** on the shelf at Dizzy
   x 60..68: it lands at (x & 0xF8)+8, which must be **48 or more**.
   - **Check:** the rat eats it and leaves you alone. Then walk the shelf to the ceiling gap at x ~196..228 and jump up
     into *The Entrance Hall* (52).
6. **Entrance Hall (52).** Lift the **railing**, take the **coin** under it (counter 1), put the railing back.
7. **Moat (51).** Rooms 52 and 51 have two levels. The **coin and the portcullis stairs are on the lower** one, the
   **lever is on the upper** one (enter 51 from 52's upper level). Take the coin (2) and throw the lever.
   - **Check:** the gate (an 8x8 sprite at x=176) rises and slams; you cannot walk through it while it is low or falling.
     **Cross under it at the top of its rise**, never while it is low or falling. With the original's pace the safe window
     is short and the port's kill box is taller (open item T0238): if you die here, retry before reporting.
8. **West Wing (67), Banquet Hall (68).** Coin in 67 (3). In 68 talk to **Denzil**, take the **rope** and the **coin** (4).
   - **Check:** his boxes play, and the **rope** appears only after them.
   The castle's upper floors are reached **on foot**, no trap needed: 51 up to 67, jump onto the table of 68, back left onto
   the ledge of 67, right again onto 68's top-left ledge, then up to the Staircase (84). 68's right exit is the fireplace
   (flames at x >= 204); the east wing, 69, is reached from 53 up.
9. **Gator (53).** Go back out and east. Drop the **rope** on the gator's back: jump from the left bank at the **start of
   its 24-pass shut stretch** (watch the mouth), stand on it and drop the rope.
   - **Check:** the gator is tied up and you can cross.
10. **Two rocks.** Take the **rock** on the gator's far bank (53), go back to the dungeon (52 hole, 36) and take the **rock**
    in the Smuggler's Hideout (35) (the third rock is in Armorog's den).
11. **Staircase and attic (84, 100).** Back up the castle by the 67-68-67-68 loop. Coin on the Staircase (5). The door
    to *The West Tower* (83) is shut for now. Get the **bone** from *The Attic* (100).
12. **Armorog (50).** Come down through the staircase hole to 68, 67, 51, east to 52, back west under the portcullis into
    50. The procedure that works:
    - Drop the **bone** from the **floor** at Dizzy x 184..191 (it must land at record x >= 192, y >= 140; dropped from a
      ledge it does not count).
    - Pick up the **third rock first** (once he sits in the den his box x 184..232 covers it).
    - Climbing down the cliff wakes him (wake box x 128..176): he counts about 40 ticks, then runs to his den at x=184 and
      kills anything in his path. There is **no idle time**: the bot needs 61-66 of the 46..60 passes the race gives.
      Climb back up the step at x ~176 (above his head) before he runs over it and wait on the ledge.
    - **Check:** once fed he stops being deadly. Leave by **jumping over his den box** to the left.

## Part 2 — Guard House, bridge, Dozy, dragon (seg 19-28, coins 6 -> 8)

13. **Guard House (49).** The hawk patrols x 32..160 and dives. It is at x >= 128 for 64 passes: cross, take the coin (6)
    and be left of x=64 inside that window. West over the boulders.
    - **Check:** it kills on contact and leaves no trail.
14. **Broken Bridge (48).** Standing on the right cliff (x 144..190) drop the 3 **rocks** one by one.
    - **Check:** each shows a message, and the water and the floating log rise 6 px each.
    - **Check:** after all 3, cross the log to the left cliff and take **key 4**.
15. **West: Fourway Warehouse (47), *The Amazing Illusion* (31), The Docks (46), Looking Out To Sea (45).**
    - 31 (coin 7): reach it by walking right off the left crate of the Warehouse -- you land on the top step. The room is a
      wall of invisible platforms; the coin (24,120) is in the pocket under the left slab. **Getting out takes a chain of
      pixel-tight jumps** (as in the original): pocket -> walk right off the ledge -> jump right x2 to the floor -> walk
      right to the block -> jump left x3 up to the pillar top -> jump left onto the small block -> walk left to its very
      edge (x=96) -> jump left onto the slab -> jump right onto the top step -> jump up. The bot does it with real keys.
    - 46: coin (8).
16. **Dozy (45).** Talk to him.
    - **Check:** the 1st talk is a **9-box conversation** and the **sleeping potion** appears (take it). Talks 2-4 are a
      repeated hint; the 5th pushes him in so he floats away left (watch for a trail). The potion needs only the first
      talk. Press DOWN where only the potion overlaps you, or the extra presses talk to Dozy instead (he wins the
      pickup order).
17. **Dragon (54).** Go back east (46, 47, the log in 48, the Guard House in its hawk window, Armorog's den, up to the moat,
    through the portcullis, the Entrance Hall, across the tied gator). Drop the **sleeping potion** from x 96..120 while
    the dragon is not breathing.
    - **Check:** he falls asleep and you can pass.

## Part 3 — Well room, tree house, volcano, hut (seg 29-38, coins 8 -> 13)

18. **Bottomless Well (55).** The coins here are **under** the leaves and the railing: lift each, take the coin
    (counter 10 after both), put it back. Pick up the **bag**.
    - **Check:** you can now carry 4 items.
19. **Over the roof of the Lift Control Hut (56).** The hut's **left wall is closed**; the way past is the **roof** (y=96):
    jump right from 55's upper ledge. On to *Base Of Tree House* (57) and *The Smelly Allotment* (58): take the **cow**.
    The **manure** (58) cannot be taken: DOWN on it just shows a message.
20. **The Large Oak Tree (59).** Talk to **Dylan**.
    - **Check:** his 3 boxes, then a single short line on later talks.
    - Lift the leaves, take the coin up in the branches (11), put the leaves back.
21. **Volcano.** *Base Of The Volcano* (60): take **key 3**. Up the slope to *The Active Volcano* (77; the lava kills): coin on
    the rocks (12). Back west to 57 for the ground coin (13), into the hut (56).
22. **Hut keys.** Drop key 4 in the hut's **bottom-right** slot (x 140..168, floor) and key 3 in its **bottom-left** slot
    (x 68..96): only the matching lift starts.

## Part 4 — Denzil's Pad, key 1, Doug, the well (seg 39-66, coins 13 -> 21)

23. **Daisy's Empty Hut (73) and Denzil's Pad (72)**, up the tree. Lift the railing in 72, take the coin (14), put it back. The
    **hole** (72): picking it up makes you drop everything you carry -- do not take it.
24. **Dozy's hut (71)** is a dead end without key 1 (88 is reachable only past a lethal torch flame from the right). Fall back
    to the well room and go west for key 1: the East Wing coin (69, from 53 up; 15), then the castle again to *The East
    Tower* (85) for **key 1**.
25. **Back to the hut (56).** Railing coin in the corridor on the hut's right side (16). Ride the hut's own lift (key 4)
    to the shelves and drop key 1 in the **top-left** slot (lift in Dozy's Hut, 71).
26. **Dozy's hut lift** up to the top-left platform of Denzil's Pad (stay at x <= 64: the torch makes the right side lethal),
    then up to the *Lift To The Elders* (88).
27. **Doug (88).** Ride the lift (it moves only while Dizzy stands within 12 px of the bar's left edge) and talk to **Doug**.
    - **Check:** his 6 boxes play and only THEN does the **crowbar** appear. Talk again: one short line, no second crowbar.
28. **Parents' Hut (89).** Take the **brass door knocker**. Back up for the coin on the hut's floor slab (17).
29. **Meeting Hall (87).** Take the **pickaxe**. The coin on the hall's lower balcony (18) is entered from 88's floor; *The Longjump
    Cloud* (86) has another (19). A plain **walk** off the cloud's right edge falls through 87 and 71 into the well room (a jump
    lands across a torch flame in 71 and kills).
30. **Well (55).** Drop the **crowbar** at x 52..68 (at 72 the right foot rests on the rim).
    - **Check:** the lid comes off and you can go down.
31. **Down the well:** *Going Down the Well* (39), *A Strange New World* (23), then *The Market Square* (22) and
    *Inside the Church* (24).
    - 22: take the coin (20). Wait in the room: after about 15 seconds the **shopkeeper** appears (both halves of his
      sprite; DOWN next to him must NOT pick him up). Drop the **cow** next to him: an 8-box bargaining conversation plays
      and a **bean** appears (any other item gets a junk reply). Take the bean.
    - 24: **key 2** and the coin (21).
32. **Back up** (falling out of the bottom of 23 runs the well loop and throws you out at the top). Into the hut: drop key 2 in the
    **top-right** slot (lift in the Dragon's Lair, 40). The four slots: top-left lift 71 (key 1), top-right lift 40 (key 2),
    bottom-left lift 88 (key 3), bottom-right the hut's own lift (key 4).
    - **Check:** each key starts its own lift only.

## Part 5 — The first lair visit, the beanstalk, the golden egg (seg 66-82, coins 21 -> 26)

33. **Dragon's Lair (40), first visit.** Ride the hut's lift down into the lair. Take the coin on the upper walkway (22), then
    go straight back up the lift: the lair's floor is lethal while the dragon is awake.
    - **Check:** the head swings and kills. The **nest egg** lying in the nest is a decoy: if you **take** it the dragon starts
      breathing fire, and putting it **back does nothing** (no message, the dragon stays awake). Only the egg from room 93 works.
34. **Window frame (73).** Via Denzil's Pad's upper platform: lift the **window frame**, then take the coin under it (23): two
    separate presses.
35. **Door and bucket.** The long way west again to the Entrance Hall, up into the castle (third time): drop the **knocker** at
    the door in *The Castle Staircase* (84).
    - **Check:** the door opens and you can walk into *The West Tower* (83). Take the **empty bucket**.
36. **Fill it.** Back east to *The Base of the Volcano* (60), drop the empty bucket at x 40..56 by the water: it becomes the
    **full bucket**. Pick it up.
37. **Beanstalk (58).** Drop the **bean** in the plant box (enter from x 136..140, clear of the manure), then the **full bucket**
    at the same spot.
    - **Check:** Dizzy is pushed left, the **beanstalk** appears, and you can climb it into *The Giant Beanstalk* (74).
38. **Clouds.** *Complex Cloud Route* (75): coin (24). *Yet More Clouds* (91) and *More 'Orrible Clouds* (92): coin (25).
    Walk RIGHT off 92's left platform to land on the coin in *Near The Volcano Top* (76; 26), then climb back up.
    - **Check:** every cloud room can be walked. Report any you can't get out of.
39. **The golden egg.** In *The Cloud Castle* (93) take the **egg**. Drop down through 92's right platform (it drops Dizzy to 59),
    walk west across the village into the hut, ride its lift and drop down the shaft into the lair (the hut's lift must be
    at the top before you step into the shaft).
40. **Lair, second visit.** Ride the lair lift down. Stand left of the nest egg (x 68..84, inside the nest's box -- standing on it,
    DOWN would pick the nest egg up) and drop the **93 egg**.
    - **Check:** the egg box appears and the dragon retracts and sleeps for good. The floor east is now safe.

## Part 6 — Mines, rug, dungeon coin (seg 83-89, coins 26 -> 28)

41. **Deserted Mines (41).** Drop the **pickaxe** by the rock on the middle-left ledge (x 36..60, y=128).
    - **Check:** the rock disappears and you can walk left. Take the coin above it (27).
42. **Miner (41).** Touch the **miner** (his box at x 232).
    - **Check:** he refuses and shoves you. The troll back in the dungeon disappears.
43. **Rug.** Back into the lair along the middle slab: pick up the **rug**. Out through 41, the lower floor, up the lair
    lift and the shaft into the hut.
44. **Dungeon coin (36).** With the troll gone the coin in his launch zone is free (28). Return up through the shelf.
45. Back east to the foot of the beanstalk and up the clouds to 92 again.

## Part 7 — Daisy's prison (seg 90-98, coins 28 -> 29)

46. **Daisy's Prison (94).** The floor has two **daggers**. Drop the **rug** at x 8..20: two **carpets** cover the daggers and you
    can walk over them safely. Before the rug, the daggers kill.
47. **Take the coin under the table FIRST** (29): lowering the lift covers it.
48. **Switch.** Jump from the carpets (x 24..32) **left** out of the room: you land on the right-hand shelf of the Cloud Castle (93).
    Walk up its steps and **jump right** from one of them: you land on the high platform of 94 (safe from the torches). Walk right
    to the switch: the lift lowers and Daisy rides it down to table height. Leave the platform to the left, round through 93's
    shelf and back into 94's left block.
    - Do NOT meet Daisy before the switch: the niche under the lift bar is a dead end (as on the Spectrum).
    - **Watch:** if the lift traps you on top of it, note exactly how you got there.
49. **Meet Daisy** (walk into her and let go of the keys).
    - **Check:** a box with the completion tune under it, then the **heart demo**: 32 hearts circle and grow around Daisy and
      Dizzy, silently. Then a second box with the tune resuming, and Daisy leaves for her hut. (The Spectrum shows three
      boxes here, the port two: known.) Daisy is drawn mirrored on alternate runs, as in the original.
50. **Back down.** 92's right platform drops Dizzy through 76 and 60 into 59. West along the village.

## Part 8 — The last coin and the ending (seg 99-106, coins 29 -> 30)

51. **The long way west:** Dozy's hut, the well room, the gator, the Entrance Hall, the castle moat and Armorog's den (fed),
    the Guard House (the hawk is at its far end for 64 passes) and over the log to the Warehouse (47).
52. **The Crafty Cloud (63), the 30th coin.** The original's note says "jump up from Fourway Warehouse" (47). The way up is the ROOF
    of the warehouse: from the ledge at x=88 (feet y=104, the platform under the crates at x 56..88) **jump right** -- the arc
    ends embedded in a one-cell stand under the thatch at (152..159, 72); walk up the 4-px steps onto it (feet y=72, x 136..152)
    and jump straight UP: Dizzy enters 63 (arriving at x=136 he lands on the cloud; from x>=140 he drops back into 47). The cap
    exists because the original's collision reads the roof's ink through the solid attribute of a blank tile (room 47 placement
    49); it is a faithful quirk, not a bug. Take the coin (30) and drop back.
    - **Check:** the coin counter reads **30**. If you're stuck below 30, note the count and which rooms you've cleared. The
      coins in 52, 55, 56, 59, 72 and 73 sit under an item (railing, leaves, window frame): lift the item first.
53. **Back east** (the log, the Guard House in its hawk window, Armorog's den, the moat, the gate, the Entrance Hall, the gator, the
    sleeping dragon, the well room), over the hut roof to the tree house and up to *Daisy's Empty Hut* (73).
54. **Walk into Daisy with 30 coins.** She should be there only **after** step 49. With fewer coins she nags you; check that too.
    - **Check:** the **completion tune** loops under her boxes, then the **heart demo** plays again.
55. The **title screen** returns.
    - **Check:** SPACE starts a fresh game: room 36, 0 coins, fire burning, Daisy back in her prison, the shopkeeper, beanstalk,
      crowbar and full bucket all gone again.

## Other things to try on the way

- The **whiskey** (Gator, 53): if you drop it you get **drunk**: Dizzy stumbles over 4 times, about every 4 seconds, and the
  bottle becomes "AN EMPTY BOTTLE".
- Troll shove, miner shove, the dagger kill and Dozy's float are one-shots that the bot's standing-still checks do not exercise;
  they have their own harnesses (`tape_miner`, `actorlife`, `tape_dozyfloat`).
- **Floppy build:** save (S) in several rooms and load (L) after dying, as described at the top.

---

**When you're done**, send your tick/cross list. "Step 32 cross: ..." is all I need, plus a `coords.py` reading for anything
that is about a place.

---

## Appendix — the playthrough bot (`tools/playthrough.sh`)

A bot plays the build with **keys only** (after loading the image) and checks the route above with closed-loop
waits, no frame counts. Use it before a human playtest, or to see the route done.

```bash
cd ports/dizzy-coco2
tools/playthrough.sh --no-build            # tape build, headless, ~55x real time: the whole route in a few minutes of wall clock
tools/playthrough.sh --no-build --floppy   # the FLOPPY build (target/dizzy.dsk in MAME's FDC; overlays read from the disk)
tools/playthrough.sh --no-build --watch    # in a MAME window at real speed, with sound (~29 emulated minutes)
tools/playthrough.sh --no-build --from 80  # resume from the checkpoint saved after segment 79
tools/playthrough.sh --no-build --until 20 # stop after segment 20 (verdict PARTIAL, exit 0 only with --until)
tools/playthrough.sh --no-build --record target/playthrough.mp4  # record a video of the run (emulated time, so full length; ~28 GB raw AVI on disk while it runs)
tools/zx_playthrough.sh                    # the SAME plan played on the Spectrum original (needs your own tape + 48K ROM)
```

- Without `--no-build` it runs `tools/tape_pack.sh` twice first (`tools/floppy_pack.sh` with `--floppy`). **Checkpoints** are MAME
  save states in `target/pt_states/` (`pt_states_floppy/` for the floppy; machine-specific, large, not in git) and **depend on
  the exact binary**: after a rebuild, run from the start once to regenerate them. **A resume is not phase-identical to a
  continuous run**: always validate from boot.
- Verdict (last line): `PLAYTHROUGH PASS` only when the win really happened (completedgame set with 30 coins, then the
  title returns); `PLAYTHROUGH FAIL seg=N step=M reason=...` plus the game state otherwise; `PLAYTHROUGH PARTIAL` when
  `--until` stopped it early. Exit status 0 only for PASS (or PARTIAL with `--until`). Current result: `segments=106 deaths=0`.
- The route is data: `harness/playthrough_route.lua` (one segment per stretch, each with a check; the CoCo and ZX bots play
  the same plan, per-machine differences are declared in `R.override`). Engine and verbs: `harness/playthrough.lua`,
  `harness/pt_engine.lua`. Dev aids: `harness/pt_survey.lua`, `pt_ascii.lua`, `pt_global.lua` (run with `PT_MODE=probe
  PT_PROBE=<file> PT_FROM=N`, see their headers), `pt_modeltest.lua` (`PT_MODE=modeltest`).
