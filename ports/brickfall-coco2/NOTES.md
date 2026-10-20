# Brickfall

`coco2` -> `coco2` (original design; third Brickfall port after c64 and zxspectrum48)

Durable findings only. Anything you would be annoyed to re-derive in three weeks
goes here: file format notes, memory maps, addresses, gotchas, dead ends and WHY
they were dead.

## Design notes

Original design: no source binary. Rules live in `games/brickfall/recipe/`; the oracle is the Rust model's golden traces.
Closest sibling: `ports/brickfall-zxspectrum48/target/brickfall.asm` (same structure, same step order, `gpf_input_ret`).

## Status (2026-10-20)

Verify: `make -C ports/brickfall-coco2/target check` (11 scenarios x2, canary rejected, ~16 s),
`make -C ports/brickfall-coco2/target smoke-keys` (read_input through MAME's emulated keyboard matrix, ~10 s),
`cargo test --offline --manifest-path factory/tools/gpfdiff/Cargo.toml` (84 tests).
Result: 11/11 scenarios bit-exact against the model's golden traces on the first run of the 6809 sim (no sim/model
disagreement was ever found), each run twice with a fresh MAME. Regression: zx48 and c64 `make check` still PASS.
Art is minimal-but-readable only (T0006 is polish); the sim section is what the harness verifies.

## Toolchain

- **lwasm 4.24** (lwtools, `pacman -S lwtools`): `lwasm --format=decb --output=brickfall.bin --map=brickfall.map --list=brickfall.lst brickfall.asm`.
  The map has `Symbol: NAME (FILE) = HEX` for labels AND `equ` constants, so `gpf_state`/`gpf_bricks` (equ) and `gpf_input_ret` (label) all
  come out of one file. `--list` is how to read what a label really assembled to.
- lwasm does not auto-extend branches: "Byte overflow" means use `lbsr`/`lblo`. `sta 128,x` silently becomes a 16-bit offset (fine).
- **MAME 0.289, machine `coco2b`**, ROMs `bas13.rom` + `extbas11.rom` in `~/.mame/roms/coco2b/` (your own; not distributed).
  Command line used by gpfdiff: `mame coco2b -rompath R -ext "" -autoboot_script gpf_mame.lua -video none -sound none -nothrottle -debug -debugger none ...`.
  A whole 3972-step scenario takes ~2 s (the machine runs ~60x real time headless).
- Loading: no disk/cassette. The Lua script writes the DECB segments into RAM at frame 150, masks IRQ/FIRQ, sets PC, reads it back
  (approach proven in dizzy-coco2's `coco_playtest.lua`; recipe `never-write-pc-from-an-emulator-script-without-checking-the-jump-actually-took`).
  It retries via `soft_reset` (<= 5x) if the program does not reach `gpf_input_ret` within 30 frames. The retry never showed up as a problem in the
  check runs, but it is not instrumented, so "never fired" is not proven.
- The 6809 register carrying the buttons is MAME's state name `A` (`cpu.state["A"]`); the ACK reads it back, `PC` too, same as zx48. Verified live.

## Memory map ($0000-$7FFF only: the stock loader cannot write $8000+, see factory/platforms/coco2.toml [load])

| Range | Use |
|---|---|
| `$1000` / `$1010` | `gpf_state` (16 B, little-endian) / `gpf_bricks` (5 B) |
| `$1020-$1034` | working copy W_* of the same block, **big-endian** 16-bit fields; `publish` byte-swaps into gpf_state |
| `$1040-$1049`, `$1060-$107F` | temps and render-only variables (R_*, T_*) |
| `$1100-$1EFF` | stack (`S = $1F00`) |
| `$2000-$37FF` | PMODE 4 frame buffer, SAM F = 16 (`$FFCF` set, other F bits cleared) |
| `$4000-` | code + tables (1.7 KB total) |

## Hardware facts used (all checked against MAME; real hardware NOT tested)

- **Video:** SAM V = 110 via `sta $FFC0 / $FFC3 / $FFC5`; frame buffer via `$FFC6 $FFC8 $FFCA $FFCC $FFCF $FFD2 $FFD0` (F0-F3 clear, F4 set, F6/F5 clear);
  PIA1 `$FF22` = `(old & 7) | $F8` (A/G=1, GM=111 = RG6 256x192, CSS=1). **STA, not LDA** for the SAM strobes (recipe
  `use-sta-not-lda-for-coco-sam-address-strobe-registers-under-xroar-mame`). 32 bytes/row, bit 7 = leftmost pixel.
- **Frame sync:** poll PIA0 `$FF03` bit 7 (CB1 field sync, set once per 60 Hz field), clear by reading `$FF02`. Control register set to `$34`
  (data register selected, falling edge, **no IRQ**); interrupts stay masked (`orcc #$50`). The flag is a latch, not a counter: a step that overruns a
  field loses fields, which only slows the game (the sim never reads time).
- **60 Hz -> 50 Hz:** accumulator `ACC += 5` each field; `>= 6` -> `ACC -= 6` and run one sim step. That is exactly 5 steps per 6 fields. Proven live: holding
  a key for 30 frames moves the paddle 25 steps x 4 px = 100 px (smoke-keys: left px=12, right px=212). `gpf_input_ret` is hit once per STEP, not per field,
  so the harness trace is per-step and identical to the 50 Hz ports.
- **Keyboard:** matrix row PA3 = `$FF00` bit 3 (active low); columns strobed low one at a time on `$FF02`: PB0 = X, PB2 = Z, PB5 = LEFT, PB6 = RIGHT,
  PB7 = SPACE (MAME ioport `:row3` fields `x  X`=1, `z  Z`=4, `LEFT`=32, `RIGHT`=64, `SPACE`=128). left = Z or LEFT arrow, right = X or RIGHT arrow,
  fire = SPACE. All columns released (`$FF02 = $FF`) after the scan. No PIA DDR setup: relies on BASIC's own configuration (as dizzy-coco2 does).
- MAME fills RAM with `$FF` at power-on; the program initialises every byte it reads, so nothing depends on it.

## Sim notes (6809)

- Same step order and the same carry-based sign logic as the Z80/6502 ports; 16-bit `addd`/`subd`; `ST*` does not touch carry (the y-move relies on that).
- `cmpa`/`suba` unsigned branches: `bhs/blo/bhi/bls`. `mod10` is the repeated-subtraction loop (cleared <= 40).
- Brick overlap windows are precomputed: row `r` overlaps iff `0 <= by-(21+8r) < 11`; column `bx>>5`, plus the next column when `(bx&31) >= 29`.
- Win is tested before miss (the 40th brick still speeds up, then WON).

## Render (minimal)

- Bricks: 32x8 with a 1 px gap right and bottom (7 solid lines + 1 blank), drawn once, erased when they die; same colour for every row (2-colour mode).
- Ball (4x4 rounded) and paddle (32x8) are XOR-drawn, ball shifted with `MUL` by `256 >> (bx&7)` (gives the 2 shifted bytes directly).
  Order per step: erase ball, bricks/HUD/message (plain writes), paddle XOR, draw ball. Same ordering rule as the ZX port (XOR commutes, plain writes do not).
- HUD: lives pips (y 8..12), 4-digit score in a 3x5 font (two digits per byte); WON = solid bar, OVER = dithered bar (no text; no font in PMODE4).
- The score shows orange in MAME: NTSC artifact colour, because the 3x5 glyph pixel columns alternate. Cosmetic, expected on a composite model.
- Screenshots were looked at by the author once (play frame and a mid-game frame); no vision-model check was run (T0006).

## Harness mutation tests (scratch builds, each vs all 11 scenarios, repeat 1)

| Mutation | Caught by |
|---|---|
| speed-up `addd #$40` -> `#$41` | full_win, speedup, wall_bounces (step 1140 ball_y) |
| paddle top `cmpa #172` -> `#173` | full_win, launch_centre, paddle_zones, speedup, wall_bounces |
| miss threshold `cmpa #193` -> `#194` | game_over (step 590), miss_dense (step 161 mode); NOT miss_then_wait (sample_every=5 hides it, as on C64/ZX) |
| brick column threshold `cmpa #29` -> `#30` | full_win, wall_bounces (step 2400) |
| row-0 score 50 -> 51 | full_win, wall_bounces |
| zone table entry `$FF40` -> `$FF41` | full_win, paddle_zones, speedup, wall_bounces |
| paddle right clamp `lda #224` -> `#223` | full_win, paddle_clamp_edges, paddle_zones, speedup, wall_bounces |
| paddle left step `suba #4` -> `#5` | 9 scenarios (everything that moves the paddle left) |
Plus the canary in `make check` (a mutated golden line must be rejected: `step 24 ... field ball_vx: expected 1 got 0`).
Equivalent mutant, not a miss: `cmpa #224` -> `#223` in the right clamp gives the same result for every reachable px (px+4 is only ever 4..228 in steps of 4,
and 224 > 223 re-clamps to 224); mutate the `lda #224` instead.

## Dead ends / gotchas (with reasons)

- **Joystick not read.** Its buttons share `$FF00` bits 0-1 with keyboard rows 0-1 and an unplugged port floats, so reading it could inject phantom
  input into a build whose input the harness cannot cover (it overwrites A). Keyboard only; adding a stick is a design call (see factory/platforms/coco2.toml [input] for the pot/button recipe).
- **First crash was my own address bug, not an emulator quirk:** `ldu #SCR+$211C` (SCR already `$2000`) wrote the score glyphs into the middle of the
  code at `$411C`; the program ran a step or two and then fell into BASIC. Symptom for the harness: first `GPF S`/ACK fine, then "timed out". Lesson: an
  address that already includes the base must not be added to it again; when a CoCo build "reaches the first stop and then dies", suspect a stray store
  over code, not the loader.
- **Diagnosing a program that runs off into BASIC:** the Lua `debugger:command("trace FILE,maincpu")` works under `-debug -debugger none`; start it at the first
  `gpf_input_ret` hit and read the file. `STU $FFFF` repeated at 3-byte strides = the CPU executing erased `$FF` RAM.
- **`-debug` run without `-rompath`** fails with "bas13.rom NOT FOUND (tried in coco2b coco)"; the Makefile defaults COCO_ROMPATH to `~/.mame/roms` when `coco2b` is there.
- Not tried: XRoar as a second oracle (not installed; the task was MAME-only).
- Not verified on real hardware: key scan, field-sync polling, PMODE4 setup. All MAME-only.

## Friction found while dogfooding `gpf` (also reported to the caller)

- `gpf init --original` seeds T0001 (recipe) and T0002 (model) as todo although `games/<game>/recipe/` already exists and is shared; they had to be retitled by hand.
- `source_platform = "coco2"` equals the target for an original; `next_action` still says "write the recipe spec".
- `gpf task edit` cannot set the task note; `gpf task done` does not run the verify string (so a verifier is only a record).
- `gpf init` creates empty `extracted/ source/ research/ harness/` dirs (git ignores empty dirs; the sibling ports have none of them).
