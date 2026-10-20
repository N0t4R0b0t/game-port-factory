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
about 14 s to the title, most of it the loader reading 170 sectors). On the floppy build two more keys work **during
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
is 28 px higher) therefore keeps **sliding a few steps in the direction of the jump** after landing, with the
jump pose, before he stops. That is faithful (measured on the ZX original), not a bug -- report it only if the
slide is *longer than 7 steps* or happens after a plain walk.

You can carry **3 items, or 4 once you have the bag** (step 15). Picking up one too many drops the
oldest. To **use** an item, stand where it's needed, press **DOWN** and choose it in the inventory
to drop it there. To **talk** to someone, walk up to them and press DOWN.

Every room shows its name in the banner. Room numbers are in brackets below so `coords.py` can
confirm where you are. Map rule: going **up** a screen adds 16 to the room number, left/right
subtract/add 1.

**What to note:** for each step, write ✅ or ❌ plus one line. Especially note:

- anything that freezes or crashes;
- graphics left behind by a moving thing (a "trail");
- a message box that needs SPACE **twice** to close;
- an item that won't drop where this guide says;
- an inventory item with the wrong name;
- anywhere you get stuck in the scenery.

**Known differences from the original** (don't report these):

- **Apple:** it lies on the floor in the dungeon instead of starting in your pocket. Giving it to
  the troll also lets you past him.
- **Heart demo:** it plays in **silence**. The music plays under the message boxes before and after
  it, but the CoCo can't run the music and animate the hearts at once.
- **Daisy:** she doesn't flip to face left and right as she does on the Spectrum.
- **Daisy's Prison (94)** runs a little slower than the other rooms.

---

## Part 1 — The dungeon and the castle

1. **Boot.** The title screen appears with music. Press SPACE.
   - **Check:** the game starts in *The Castle's Dungeon* (36), with lives and 0 coins shown.
2. **Fire (36).** Pick up the **jug of water** and drop it at the fire.
   - **Check:** the fire goes out and stays out.
3. **Rat (36).** Pick up the **loaf** (you can't avoid it: it lies where you collect the apple). The
   rat patrols the **shelf** (y=80) that only step 5's route reaches, so you drop the loaf there, not
   from the floor. The loaf lands at (x & 0xF8)+8, which must be **48 or more**: the rat only patrols x 48..192.
   - **Check:** the rat takes it and leaves you alone.
4. **Troll (36).** Pick up the **apple** and drop it by the troll.
   - **Check:** he takes it and lets you past. Collect the dungeon coin.
5. **Out of the dungeon.** You can **not** climb out from the dungeon floor: the slab at y=80..102 is
   solid across the whole width. The way (found by the bot): with the fire out go **left** to
   *The Smuggler's Hideout* (35), climb onto its right pillar (y=80) and leave **right**: you arrive on the
   dungeon's **shelf** (y=80, x=8). That is where the rat is (step 3). Walk the shelf to the ceiling gap at x ~196..228
   and jump up into *The Entrance Hall* (52).
6. **Moat (51).** Rooms 52 and 51 have two levels. The **lever is on the upper level** (enter 51 from 52's
   upper level); the coin and the portcullis stairs are on the **lower** one. The gate (an 8x8 sprite at x=176) rises
   1 px per frame pass from 136 to 98 and then slams down 2 px per pass: **cross at the top of its rise**, never
   while it is low or falling. Use the lever to raise the portcullis and pass under it.
   - **Check:** it opens and closes, and you can't walk through it while it's down.
7. **Banquet Hall (68)**. The castle's upper floors are reached **on foot**, no trap needed: 51 up to
   *West Wing* (67), jump onto the table of 68, back left onto the ledge of 67, right again onto 68's top-left
   ledge, then up to the Staircase (84). (68's right exit is the fireplace: flames at x >= 204; the
   east wing, 69, is reached from 53 up.) Talk to **Denzil**.
   - **Check:** his boxes play, and the **rope** appears.
8. **Gator (53).** Drop the **rope** on the gator's back: jump from the left bank at the **start of its
   24-pass shut stretch** (watch the mouth: it stays closed for a while), stand on it and drop the rope.
   - **Check:** the gator is tied up and you can cross.
9. **East and West Wings (69, 67).** Watch for the dagger trap in the East Wing. Collect the coins.
10. **Staircase, towers, attic (84, 85, 100).** Get the **bone** from *The Attic* (100). The door to
    *The West Tower* (83) is shut for now.
11. **Armorog (50).** Drop the **bone** for the Armorog. The procedure that works:
    - Climbing down the cliff wakes him (his wake box is x 128..176): he counts about 40 frames and then runs to his den
      at x=184, killing anything in his path. Be quick, you have about 60 passes.
    - Drop the **bone** from the **floor** at Dizzy x 184..191 (it must land at record x >= 192, y >= 140; dropped from a
      ledge it does not count).
    - Pick up the **third rock first** (once he sits in the den, his box x 184..232 covers it), then climb back up the
      step at x ~176 (above his head) *before* he runs over it, and wait on the ledge.
    - Leave by **jumping over his den box** to the left.
    - **Check:** he stops being deadly.

## Part 2 — Dozy, the dragon, the hut and the well

12. **Looking Out to Sea (45).** Talk to **Dozy**.
    - **Check:** the 1st talk shows a **9-box conversation** and the **sleeping potion** appears.
    - **Check:** talks 2–4 say "kick him", and the 5th pushes him in, so he floats away to the left.
      Watch for a trail behind him. (The potion needs only the first four talks.)
13. **Dragon (54).** Drop the **sleeping potion** at the dragon.
    - **Check:** he falls asleep and you can pass.
14. **Lift Control Hut (56) and east.** The hut's **left wall is closed**: you enter the interior from
    *57*'s ground, and the **roof** (y=96) is reached by jumping right from 55's upper ledge. After taking 57's
    ground, the way back to the upper level is 57 -> 58's tree platform -> 57. Go east past the hut to
    *The Base of the Volcano* (60) and take **key 3**. Drop it in the hut's **bottom-left** slot.
    - **Check:** only the lift to the Elders (88) starts.
15. **Bottomless Well (55).** The coins here are **under** the leaves and the railing: pick those
    up first. Pick up the **bag**.
    - **Check:** you can now carry 4 items.
16. **Lift to the Elders (88).** Ride the lift up and talk to **Doug**.
    - **Check:** his 6 boxes play and only THEN does the **crowbar** appear. Talk again and he says
      one short line ("go on my son"), with no second crowbar.
17. Back at the **well (55)**, drop the **crowbar** at the lid.
    - **Check:** the lid comes off and you can go down.
18. **Down the well:** *Going Down the Well* (39), then *A Strange New World* (23), then *The Market
    Square* (22) and *Inside the Church* (24). Collect the coins and key 2 (in the church).

## Part 3 — Keys and lifts (Lift Control Hut, 56)

19. Collect the other keys: *East Tower* (85) and *The Broken Bridge* (48; see step 22). Drop each one
    in the hut **in its own slot**:
    - top-left: lift in Dozy's Hut (71);
    - top-right: lift in the Dragon's Lair (40);
    - bottom-left: lift to the Elders (88), done in step 14;
    - bottom-right: the hut's own lift (56).

    **Check:** each key starts its own lift, and the other lifts don't move.

## Part 4 — Tree house, river, hawk, mines, dragon's lair

20. **The Large Oak Tree (59).** Talk to **Dylan**.
    - **Check:** his 3 boxes, then on later talks one "trance" line.
21. **Items to look out for:**
    - The **whiskey** (Gator, 53): if you drop it you get **drunk**. Dizzy stumbles over 4 times on
      his own, about every 4 seconds, and the bottle becomes "AN EMPTY BOTTLE".
    - The **hole** (Denzil's Pad, 72): picking it up makes you **drop everything** you carry.
    - The **manure** (Smelly Allotment, 58): DOWN on it just shows a message; you can't take it.
22. **Broken Bridge (48).** Carry the 3 **rocks**, from Armorog's Den (50), the Smuggler's Hideout
    (35) and the Gator (53), and drop each in the river from the right-hand cliff.
    - **Check:** each rock shows a message, and the water and the floating log rise.
    - **Check:** after all 3, jump from the log to the left cliff and take **key 4**.
23. **Guard House (49).** A hawk patrols and dives.
    - **Check:** it kills on contact and leaves no trail. Get the coin.
24. **Deserted Mines (41).** Touch the **miner**.
    - **Check:** "go away" and a shove. The troll back in the dungeon disappears.
25. **Pickaxe.** Get the **pickaxe** from *The Meeting Hall* (87) and drop it by the **rock** on the
    left ledge of the Mines (41).
    - **Check:** the rock disappears and you can walk left.
26. **Dragon's Lair (40).** *As in the original, the lair cannot be passed yet.* The dragon's head swings and
    kills on contact, and the only thing that calms it is **the golden egg from the Cloud Castle (93)**
    dropped in the nest box (do this after the beanstalk, Part 6: take the egg from 93, carry it back down
    through the village, the hut and the well shaft). So for now just look:
    - **Check:** the head swings and kills (death line about the dragon); the **nest egg** lying in the nest is
      a decoy: if you **take** it the dragon starts breathing fire, and putting it **back does nothing** (no
      message, the dragon stays awake).
    - **Check (after fetching the egg from 93):** dropping the **93 egg** in the nest shows the "put the egg back"
      box and the dragon retracts and sleeps for good. Then get the coin and pick up the **rug** (needed
      for step 34).

## Part 5 — Door, bucket, shopkeeper, beanstalk

27. **Door knocker.** Get the **brass door knocker** from *Dizzy's Parents' Hut* (89). Drop it at the
    door in *The Castle Staircase* (84).
    - **Check:** the door opens and you can walk into *The West Tower* (83).
28. **Empty bucket.** Take the **empty bucket** from the West Tower (83). Drop it at the well in
    *The Base of the Volcano* (60).
    - **Check:** it becomes a **full bucket** ("A BUCKET OF WATER"). Pick it up.
29. **The Smelly Allotment (58):** pick up the **cow**.
30. **The Market Square (22):** wait in the room. After about 15 seconds the **shopkeeper**
    appears with a message.
    - **Check:** he appears with both halves of his sprite. Pressing DOWN next to him must NOT
      pick him up.
31. Drop the **cow** next to him.
    - **Check:** an 8-box bargaining conversation plays and a **bean** appears. Dropping anything
      else gives a "junk" reply.
32. **The Smelly Allotment (58):** drop the **bean** on the manure ("unable to grow"), then drop the
    **full bucket** at the same spot.
    - **Check:** Dizzy is pushed left, the **beanstalk** appears, and you can climb it into
      *The Giant Beanstalk* (74).

## Part 6 — The clouds, Daisy's prison, the last coins

33. Explore *Complex Cloud Route* (75), *Yet More Clouds* (91), *More 'Orrible Clouds* (92) and
    *The Cloud Castle* (93). Collect the coins in 75 and 92.
    - **Check:** every cloud room can be walked. Report any you can't get out of.
34. **Daisy's Prison (94).** The floor has two **daggers**.
    - **Check:** drop the **rug** in the room. Two **carpets** cover the daggers and you can walk over
      them safely. Before the rug, the daggers kill.
    - **Take the coin under the table FIRST** (lowering the lift covers it). Then jump from the carpets (x 24..32) **left** out of the room:
      you land on the right-hand shelf of the Cloud Castle (93). Walk up its steps and **jump right** from one of them: you land on the
      high platform of 94 (safe from the torches). Walk right to the switch: the lift lowers and Daisy rides it down to table height.
      Leave the platform to the left, go round through 93's shelf and back into 94's left block, then meet Daisy (step 35).
      Do NOT meet Daisy before the switch: the niche under the lift bar is a dead end (as on the Spectrum).
    - **Watch:** if the lift traps you on top of it, note exactly how you got there.
35. **Meet Daisy** (walk into her and let go of the keys).
    - **Check:** a box with the completion tune under it, then the **heart demo**: 32 hearts circle
      and grow around Daisy and Dizzy, silently. Then a second box with the tune resuming, and
      Daisy leaves for her hut. (Coin 94 is taken before the switch, see step 34.)
36. **Remaining coins:**
    - *The Crafty Cloud* (63): the original's note says "jump up from Fourway Warehouse" (47). The way up is the
      ROOF of the warehouse (T0232): from the ledge at x=88 (feet y=104, the platform under the crates at x 56..88)
      **jump right** -- the arc ends embedded in a one-cell stand under the thatch at (152..159, 72); walk up the
      4-px steps onto it (feet y=72, x 136..152) and jump straight UP: Dizzy enters 63 (arriving at x=136 he lands on the
      cloud; from x>=140 he drops back into 47). The cap exists because the original's collision reads the roof's ink
      through the solid attribute of a blank tile (room 47 placement 49); it is a faithful quirk, not a bug.
      (Not yet exercised end to end by the bot: see NOTES.md T0232.)
    - *Near the Volcano Top* (76);
    - *The Active Volcano* (77; the lava kills);
    - *The Longjump Cloud* (86);
    - *Dizzy's Parents' Hut* (89);
    - *The Meeting Hall* (87);
    - the tree-house rooms (57, 59, 72);
    - *The Docks* (46);
    - *The Amazing Illusion* (31): reach it by walking right off the left crate of the Warehouse (47) -- you land on the top step.
      The room is a wall of invisible platforms. The coin (24,120) is in the pocket under the left slab. **Getting out takes a chain
      of pixel-tight jumps** (as in the original): pocket -> walk right off the ledge -> jump right x2 to the floor -> walk right
      to the block -> jump left x3 up to the pillar top -> jump left onto the small block -> walk left to its very edge (x=96)
      -> jump left onto the slab -> jump right onto the top step -> jump up. The bot does it with real keys (NOTES.md T0232).

    The coins in 52, 55, 56, 59, 72 and 73 sit under an item (railing, leaves, window frame): lift
    the item first.
    - **Check:** the coin counter reaches **30**. If you're stuck below 30, note the count and
      which rooms you've cleared.

## Part 7 — The ending

37. **Daisy's Empty Hut (73).** She should be there only **after** step 35. Walk into her with 30
    coins. With fewer, she nags you; check that too.
    - **Check:** the **completion tune** loops under her boxes, then the **heart demo** plays again.
38. The **title screen** returns.
    - **Check:** SPACE starts a fresh game: room 36, 0 coins, fire burning, Daisy back in her prison,
      the shopkeeper, beanstalk, crowbar and full bucket all gone again.

---

**When you're done**, send your ✅/❌ list. "Step 32 ❌: ..." is all I need, plus a `coords.py`
reading for anything that's about a place.

---

## Appendix — the playthrough bot (`tools/playthrough.sh`)

A bot plays the tape build with **keys only** (after loading the image) and checks the route above with closed-loop
waits, no frame counts. Use it before a human playtest, or to see the route done.

```bash
cd ports/dizzy-coco2
tools/playthrough.sh --no-build            # headless, ~55x real time: the whole route in about 30 s
tools/playthrough.sh --no-build --watch    # in a MAME window at real speed, with sound (~26 emulated minutes)
tools/playthrough.sh --no-build --from 80  # resume from the checkpoint saved after segment 79
tools/playthrough.sh --no-build --until 20 # stop after segment 20 (verdict PARTIAL, exit 0 only with --until)
tools/playthrough.sh --no-build --record target/playthrough.mp4  # record a video of the run (emulated time, so full length; ~24 GB raw AVI on disk while it runs, ~50 MB MP4 after)
```

- Without `--no-build` it runs `tools/tape_pack.sh` twice first. **Checkpoints** are MAME save states in
  `target/pt_states/` (machine-specific, large, not in git) and **depend on the exact binary**: after a rebuild, run from
  the start once to regenerate them.
- Verdict (last line): `PLAYTHROUGH PASS` only when the win really happened (completedgame set with 30 coins, then the
  title returns); `PLAYTHROUGH FAIL seg=N step=M reason=...` plus the game state otherwise; `PLAYTHROUGH PARTIAL` when
  `--until` stopped it early. Exit status 0 only for PASS (or PARTIAL with `--until`).
- The route is data: `harness/playthrough_route.lua` (one segment per stretch, each with a check). Engine and verbs:
  `harness/playthrough.lua`, `harness/pt_engine.lua`. Dev aids: `harness/pt_survey.lua`, `pt_ascii.lua`, `pt_global.lua`
  (run with `PT_MODE=probe PT_PROBE=<file> PT_FROM=N`, see their headers), `pt_modeltest.lua` (`PT_MODE=modeltest`).
