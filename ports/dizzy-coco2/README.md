# Fantasy World Dizzy for the Tandy CoCo 2

A reimplementation of *Fantasy World Dizzy* (Oliver Twins / Codemasters, ZX Spectrum 1989) for the Tandy Color Computer 2
(6809, 64K, PMODE 4 artifact graphics, 1-bit DAC sound). It is a new 6809 engine, not a translation of the Z80 code: the
rules, tables, room layout and art come from the Oliver Twins' released source, converted by the tools in `tools/`. The whole
game is playable in the tape and floppy builds: every puzzle, all 30 coins, Daisy, the ending (the `-run` test build has only
the 31 base rooms). Status and the latest handoff: `gpf status dizzy-coco2` (from the repo root).

**Nothing of the original ships in this repo.** You supply the source files and ROMs; the build generates everything derived
from them locally (and gitignored). See `docs/PROVENANCE.md`.

## The three builds

| Build | File | How it boots | What it is |
|---|---|---|---|
| `-run` test build | `target/room36.bin` | XRoar `-run` (loads the DECB binary directly) | The development build: the 31 base rooms only, no tape-only content, no joystick. Used by the early harnesses. Not the complete game. |
| **TAPE** | `target/room36.cas` | one `CLOADM` + `EXEC` | The **complete game**, delivered as a single cassette load. Analog **joystick** support (also in the floppy build). 39 bytes of RAM free: it is full. Scenery that sits at negative x in the original is not drawn (it is partly off-screen, see "Known differences"). |
| **FLOPPY** | `target/dizzy.dsk` | Disk BASIC: `LOADM"DIZZY":EXEC` | The tape content plus: the title screen and the heart demo read from `DIZZY.OVL` on demand (a private WD1793 driver, no DSKCON), a one-slot **quick save** (`S` to save, `L` to load, `DIZZY.SAV` on the disk), and the **left-edge scenery** drawn clipped as on the Spectrum. About 14 s to the title (the loader reads 168 sectors). 1391 bytes free. Needs 64K and RS-DOS. |

All three come from the same sources (`target/room36.asm` and friends); `tools/stage_pack.sh`, `tools/tape_pack.sh` and
`tools/floppy_pack.sh` build them. Do not call `lwasm` by hand: the staged blocks are LZSS-packed in a two-pass build and a bare
assemble refuses on purpose.

## Prerequisites

* **Your own media**, exactly as listed in `tools/inputs.toml` (pinned by sha256): the Oliver Twins' released source and
  data for the game (the `picosonic/D3` checkout at commit `4ac31df`), and the CoCo ROMs `BASIC.ROM`, `EXTBASIC.ROM`,
  `DSKBASIC.ROM` (run-only). Optional, harnesses only: a Fantasy World Dizzy `.tzx` dump and the Spectrum 48K ROM
  (`spectrum.zip`) for the original-vs-port comparisons. Nothing is downloaded for you.
* Tools on the PATH: `lwasm` (lwtools), `cargo` (Rust, builds offline), `python3`, `xroar` (play and the tape/floppy boot
  checks), `mame` with the `coco2b` and `spectrum` sets (the bots and harnesses), `ffmpeg` (videos only).
* Generate the build inputs, from the port directory:

```bash
cd ports/dizzy-coco2
tools/bootstrap.sh --d3 /path/to/your/D3 --roms /path/to/coco/roms   # verify by sha256, extract, generate text/art/sound, build all three
tools/bootstrap.sh --list                                           # the steps
tools/bootstrap.sh --verify                                         # afterwards: the five artifacts must match docs/BUILD-HASHES.txt
```

If a build artifact is missing or stale after a pull, re-run the bootstrap (or `--steps` for the affected steps); it never
touches your sources.

## Build and play

`play.sh` builds and launches XRoar. Read its header for the full text; the flags are:

```bash
./play.sh                    # build the -run test build and play it
./play.sh --tape             # build + boot target/room36.cas with a real CLOADM + EXEC (the complete game)
./play.sh --floppy           # build + boot target/dizzy.dsk with LOADM"DIZZY":EXEC (disk attached write-back)
./play.sh --no-build ...     # run what is already in target/ (--tape / --floppy need their file to exist)
./play.sh --tape --inf-lives # playtest aid: a death still shows its box and respawns, but costs no life (build-time flag)
./play.sh --tape 51          # a leading NUMBER = start in that room (build-time, so not with --no-build); the items that room's
                             #   puzzle needs are seeded (tools/room_items.py); --no-items suppresses, or give a list (max 3):
./play.sh --tape 53 rope     #   rope apple whiskey jug loaf railing
./play.sh --tape -- <xroar args>   # everything after -- goes to xroar, e.g. -no-tape-fast to time a real-speed load
PLAY_GDB=1 ./play.sh --tape        # opens xroar's gdb stub; `python3 tools/coords.py` prints the room and Dizzy's x/y
```

A later plain `./play.sh` rebuilds without `--inf-lives` / the start room. PMODE 4 on a composite CoCo produces red/blue
edging on fine detail; that is real hardware behaviour. `./play.sh -- -vo-monochrome` shows the underlying black and white.

### Controls

| Input | Action |
|---|---|
| Left / Right | walk |
| Up | jump (committed: no air control, as in the original; landing on a higher surface slides a few steps) |
| Down | pick up, drop, talk, open the inventory |
| Space | dismiss a message, choose in the inventory |
| **S** / **L** (floppy only) | quick save / quick load, one slot. Ignored in boxes, in the air, when dead or in the well; boxes report an empty slot, a save from another build, or a disk error |
| Right joystick (tape and floppy builds) | X axis walks, **slower-only**: full tilt = the keyboard's speed, a partial tilt 3/4, 1/2 or 1/4 of it, the middle quarter is a dead zone. Fire = jump (sideways at full speed if the stick is pushed) and also dismisses boxes / selects. Keep the stick centred at start. Under XRoar: `./play.sh --tape -- -joy-right mjoy0` (mouse) or `-joy-right kjoy0` (cursor keys + Alt_L); a gamepad needs its own `-joy` profile (`xroar -joy help`). Verified in MAME on the tape build; the floppy build carries the same code (untested there); not tried on hardware |

Infinite lives, start rooms and the step-by-step walkthrough for a tester: `docs/PLAYTEST-GUIDE.md`.

## Playthrough bots and videos

A closed-loop bot plays the whole game with real keys (no frame counts, no teleports except where noted) and checks every
step. The route is one shared 106-segment plan (`harness/playthrough_route.lua`) played on both machines.

| Command | What it does |
|---|---|
| `tools/playthrough.sh [--no-build]` | the TAPE build in MAME, headless, fast. Last line `PLAYTHROUGH PASS segments=106 deaths=0` (exit 0), or `FAIL seg=N ...` |
| `tools/playthrough.sh --floppy` | the FLOPPY build with MAME's FDC; the game itself reads its overlays from the disk image (a private copy) |
| `... --watch` | in a MAME window at real speed with sound (about 29 emulated minutes) |
| `... --from N` / `--until N` | resume from the checkpoint after segment N-1 / stop after segment N (`PARTIAL`). Checkpoints are binary-specific and a resume is not phase-identical to a run from boot: validate from boot |
| `... --record out.mp4` / `--raw out.avi` | record the run (about 28 GB of raw AVI while it runs); `--raw` keeps the AVI for the side-by-side composer |
| `tools/zx_playthrough.sh [--from N] [--until N] [--record out.avi]` | the same plan on the Spectrum original (needs your tape and ROM); `ZXPLAYTHROUGH PASS` |
| `tools/side_by_side.sh` | composes the CoCo (left) and Spectrum (right) recordings, segment-synced, equal-size rooms, 1536x660. Inputs default to `target/pt_tmp/{coco,zx}_raw.avi` + logs; `COCO_LABEL=...` sets the left label. Recipe for both final videos: NOTES.md `## T0256` |
| `tools/verify_side_by_side.sh [video.mp4]` | checks the video (size, audio, both halves non-blank at every segment) |
| `tools/verify_zx_playthrough.sh` | both ZX runs pass and are byte-identical, and every paired segment ends in the same room on both machines |

## How fidelity is verified

* **Room by room**: `tools/roomcmp.sh [--entries]` saves a MAME state at the first entry into every room on both machines,
  records every actor for 400 ticks with no key pressed, and `tools/roomcmp` (Rust) compares them per actor and channel
  (also over the whole bot runs: dialogue order, animation). Every deviation is either fixed or named with its reason in
  `tools/roomcmp/expectations.toml`. `tools/hazardcmp.sh ROOM` sweeps Dizzy over a grid on both machines and diffs where he dies.
  Results and the table per room: `docs/ROOM-FIDELITY.md`.
* **Verifiers** (each prints a final PASS/FAIL line and exits non-zero on failure; `NOBUILD=1` reuses `target/`; run one emulator
  at a time):

| Script | Last line | What it proves |
|---|---|---|
| `tools/bootstrap.sh --verify` | steps OK | the five artifacts match `docs/BUILD-HASHES.txt`; no personal paths in generated files |
| `tools/verify_verbatim.py` | exit 0 | every sprite byte equals a straight decode of the original art (no lossy transform) |
| `tools/verify_roomcmp255.sh` | `VERIFY_ROOMCMP255 PASS` | the comparer's canary, every message stream equals the original byte for byte, both bots, all rooms' actors, dialogue order, 9 hazard sweeps (~25 min) |
| `tools/verify_zx_playthrough.sh` | `ALL CHECKS PASSED` | the ZX bot is deterministic and paired with the CoCo bot segment by segment |
| `tools/verify_beanstalk.sh` | `VERIFY_BEANSTALK PASS` | shopkeeper, bean, plant, water, beanstalk; real XRoar tape boot |
| `tools/verify_items226.sh`, `verify_items227.sh`, `verify_items230.sh` | `VERIFY_ITEMS2xx PASS` | knocker/bucket/pickaxe; rug/carpets/bag/inventory names; hole/whiskey/manure |
| `tools/verify_people229.sh`, `verify_daisy228.sh` | `VERIFY_PEOPLE229 PASS`, `VERIFY_DAISY228 PASS` | Dylan and Doug; Daisy's prison, the lift, the heart demo, the ending, collision masks |
| `tools/verify_joystick.sh` | `VERIFY_JOYSTICK PASS` | the analog stick (35 checks: slower-only, dead zone, fire, unarmed stick ignored) |
| `tools/verify_floppy241.sh` | `VERIFY_FLOPPY241 PASS` | the disk: real boot, every byte of the image, overlays, the floppy bot (`BOT=1`) |
| `tools/verify_floppy242.sh` | `VERIFY_FLOPPY242 PASS` | quick save/load: round trips, bad slots, no disk, XRoar reboot, the bot saving and loading mid-game |

Regeneration of the sprites, rooms and collision data is in `tools/regen_art.sh`; `ROOM36_REF=<reference room36.bin>` makes
most verifiers also check that the `-run` build is byte-identical to a known good one.

## Known differences from the original

Full list with reasons: `docs/ROOM-FIDELITY.md` (fixed F1-F13, expected E1-E7, decided D1-D4, open D5). In short:

* **Expected, kept on purpose**: the rat starts on its patrol rather than just off-screen; the dragon's breath roll and the rat's
  leg lengths follow the original's rules with a different random generator; the miner is parked off-screen until his trigger;
  the water tile at x=-16 px in rooms 45 and 46 cannot be drawn (the 16 px strip has no water and no drowning box); the apple
  lies on the dungeon floor instead of starting in the pocket (and lets you past the troll); the heart demo is silent (the 1-bit
  DAC and the animation cannot share the CPU); the ZX plays its sound through the AY chip, the port through the DAC.
* **Tape build only**: scenery placed at negative x (20 pieces in 11 rooms) is not drawn; the floppy build draws it clipped.
* **Open**: **T0238** the port's kill box is 7 px taller than the original's (it makes the portcullis crossing in room 51 tighter;
  a user decision); **T0239** the death-animation countdown and the drunk timer still run on Dizzy's clock rather than the 4/3
  actor clock; the floppy boot could be about 4x faster with interleave-aware reads (not done: a design call); the joystick has
  not been run in XRoar beyond the profile names, and **nothing has been tested on real hardware** (disk driver timing, tape
  load, joystick pots).

## Docs map

| Document | Read it for |
|---|---|
| `docs/PLAYTEST-GUIDE.md` | the step-by-step route a human tester follows, in the order the bot plays it; controls, quick save, joystick |
| `docs/ROOM-FIDELITY.md` | fidelity summary, per-room table, the F/E/D lists, hazards, dialogue/animation/sound comparison |
| `docs/SOLUTION-PATH.md` | the puzzle dependency graph, the 30 coins, the coin order the bots play |
| `docs/PROVENANCE.md` | what is yours / ours / generated, the text policy (no original dialogue in tracked files) and its gates |
| `docs/BUILD-HASHES.txt` | the five build artifacts' hashes (`tools/bootstrap.sh --verify`) |
| `NOTES.md` | durable findings, chronological; start at its INDEX. Memory map, loaders, every dead end with its reason |
| `tools/roomcmp/README.md`, `tools/textsplit/README.md` | the two tools with their own documentation |
| `tasks.toml`, `SESSION-LOG.md` | task history; `gpf status dizzy-coco2` for the handoff and the next task |

## For a developer or agent continuing the work

1. `gpf status dizzy-coco2`, then the INDEX at the top of `NOTES.md`.
2. Rebuild loop: edit `target/room36.asm` or the tracked text templates in `target/text_tpl*/` (the `text_src*` copies are
   generated, never hand-edit them), run `tools/bootstrap.sh --steps fill_text,harness_text,dte,stage,tape,floppy`, then
   `tools/tape_pack.sh` twice. Check the free bytes with `tools/ramaudit.py` (tape 39 B, floppy 1391 B: anything new needs
   space first).
3. Scope your verification to the change: the one harness that reproduces it plus the build guards; the full bots and
   `verify_roomcmp255.sh` only for app-wide changes. A resume from a checkpoint is not proof; validate from boot.
4. New derived data must be generated and gitignored (and added to `.public-exclude`) before it is committed; never quote the
   game's dialogue in a tracked file (`docs/PROVENANCE.md`, gate: `tools/textsplit`).
