# Brickfall

`c64` -> `c64`

Durable findings only. Anything you would be annoyed to re-derive in three weeks
goes here: file format notes, memory maps, addresses, gotchas, dead ends and WHY
they were dead.

## Source inventory

_TBD — task T0001_

## Engine / toolchain

_TBD — task T0002_

## Prior art

_TBD — task T0003_

## Format notes

## Dead ends

## Session 2026-10-17 findings
- **sjasmplus install:** `yay -S` builds the AUR package but fails at the sudo step in a non-interactive session. Workaround used: extract `usr/bin/sjasmplus` from `~/.cache/yay/sjasmplus/*.pkg.tar.zst` into `~/.local/bin/`. `sjasmplus --version` is not a valid flag (errors, but the binary works).
- **Friction (T0008):** `gpf init` seeds identify/classify tasks that assume an existing original. For original designs they were closed as N/A by hand.
- **Public repo:** this port lives in the public staging repo (`game-port-factory-public`), not the private archive.

## T0010/T0011: C64 build + gpfdiff harness (2026-10-17)

Files: `ports/brickfall-c64/target/{brickfall.asm,Makefile}`, harness crate `factory/tools/gpfdiff/`
(placed in factory/ at the caller's explicit instruction; second caller will be the ZX backend).
Verify: `make -C ports/brickfall-c64/target check` (~2 min: 10 scenarios x 2 runs + canary) and
`cargo test --manifest-path factory/tools/gpfdiff/Cargo.toml`. Result: 10/10 scenarios bit-exact, each run twice.

### C64 build facts
- Memory: BASIC stub at $0801 (SYS 2064), code from $0810, sprite data (ball, paddle) 64-aligned before $1000
  (VIC bank 0 sees char ROM at $1000-$1FFF; the asm asserts the image ends below $1000). `gpf_state=$C000`,
  `gpf_bricks=$C010` are plain `=` constants (RAM outside the PRG), so they appear in the `--vicelabels` file.
- Sim works on a zero-page working copy ($20-$34) and `publish` copies 21 bytes to gpf_state/gpf_bricks at the end of the step.
- Frame sync: SEI, no IRQs at all; poll $D012 for line 251 (leave 251 first so a fast step cannot run twice). PAL 50 Hz.
  Sim state does not depend on raster timing, so traces are independent of boot timing.
- `gpf_input_ret` is the label ON the RTS of read_input; VICE exec checkpoints fire before the instruction executes,
  so overwriting A there changes what the RTS returns.
- Keyboard matrix used: Z = write $FD read $DC01 bit4; X = $FB bit7; SPACE = $7F bit4 (DDRA output while scanning, restored to input
  so joystick 2 reads cleanly). Joystick 2: $DC00 active low, bit2 left, bit3 right, bit4 fire.
- Rendering is minimal on purpose: bricks = 4-char reverse-space blocks (alternating colours per column), ball and paddle = sprites
  (paddle = x-expanded sprite), playfield char col 4 / row 0 / raster 51 => sprite X = 56+x, Y = 50+y. Status text on row 24. NOT looked at
  by any check (art is a later task); sprite offsets are from the VIC docs, never eyeballed.

### VICE 3.10 binary monitor (what the harness learned the hard way)
- Framing: STX 02, API 02, len u32 (body only), id u32, cmd; reply: STX 02 API 02 len u32 type u8 err u8 id u32. Events have id 0xFFFFFFFF.
- Event types: 0x62 = STOPPED (body PC), 0x63 = RESUMED, 0x31 regs, 0x11 checkpoint info. (My memory had stopped/resumed swapped; the
  manual's table in the spec is the authority: 0x62 stopped, 0x63 resumed.) A checkpoint hit sends 0x11 (CH=1), 0x31, 0x62 in that order.
- ANY command sent while the CPU runs stops it (at an arbitrary PC) and emits 0x31+0x62. First command after connect is a ping for this reason.
- The reply to exit (0xaa) can arrive before OR after the resumed/stopped events. Track a `stopped` flag from the event stream, not from reply order.
- Register IDs must be looked up with 0x83 (A=0, PC=3 on x64sc 3.10 today). Registers-set (0x32) replies; harness re-reads A and PC afterwards.
- Checkpoint set body: start u16, end u16, stop u8, enable u8, op u8 (4 = exec), temporary u8. Memory get: side-effects u8, start, end(inclusive), memspace 0, bank u16.
- **Autostart (0xdd) resumes the machine itself** (0x63 event). DEAD END: sending exit (0xaa) right after autostart stopped the CPU at random
  KERNAL PCs ($fd75, $e5d4, ...) hundreds of times (154 spurious stops, then a failure inside my own code). Correct sequence:
  ping -> regs-avail -> set checkpoint -> autostart -> wait for the resume event -> wait for the stop event -> verify PC == gpf_input_ret.
  Set the checkpoint BEFORE autostart so step 0 cannot be missed.
- Launch: `xvfb-run -a x64sc -default -model c64 -warp +sound -autostartprgmode 1 -binarymonitor -binarymonitoraddress ip4://127.0.0.1:PORT`.
  `-default` first so ~/.config/vice can never change a result. Free port from bind(:0). Without xvfb the window opens on the user's desktop (DISPLAY=:1).
  Shutdown: 0xbb quit, then kill the whole process group (xvfb-run + Xvfb + x64sc) after 3 s.
- Speed: 3972-step scenario ~ 10 s/run in warp (about 6 monitor round trips per step); whole check ~ 2 min. Scenarios run sequentially (OOM rule).
- Each `--repeat` run boots a fresh emulator, so repeat equality proves cold-boot determinism, not just a re-run.
- DEAD END: `joyport set` (0xa2) over the binary monitor did nothing ($DC00 stayed $FF) for ports 0-4 with -controlport{1,2}device 1. Real
  input paths were instead smoke-tested once by hand with xdotool key events into an Xvfb-hosted x64sc (`-joydev2 1`): z -> A=1, x -> 2,
  space -> 4, numpad4 -> 1, numpad6 -> 2, numpad0 -> 4 (joystick fire). Delivery lags ~3 s of emulated time and key-up is unreliable under Xvfb
  without a WM, so this is NOT automated in `make check`. The shipped read_input is therefore verified by hand only.

### Harness (gpfdiff) design
- `target.rs`: trait `Target` { boot, read_state, provide_input, shutdown } = "parked at the input point" primitives; `run_scenario` is the
  platform-independent loop (sample when step % sample_every == 0, then inject buttons for index i). A MAME/ZX backend only implements the trait.
- Desync gate: at input point i the target's own `step` field must equal i, otherwise a harness error (never a diff).
- Determinism is checked BEFORE the golden diff (NON-DETERMINISTIC report), per the recipe.
- `make check` includes a canary: a mutated golden line must make gpfdiff fail with `step 10 ... field ball_vx: expected 1 got -128`.
- Mutation-tested by hand against scratch builds: adc #$40->#$41 (speedup), paddle y threshold, brick column threshold, each caught with a
  correct step/field. Known blind spot: changing the miss threshold (`cmp #193`->`#194`) is NOT caught by miss_then_wait because sampling is
  every 5 steps and the re-attached ball hides the one-step difference. Candidate for a sample_every=1 miss scenario (top-tier call; scenarios are recipe).

## Review notes (top tier, 2026-10-17)
- Independently re-ran: gpfdiff 25/25, model 9/9, `make check` 11 scenarios x2 deterministic, canary rejected.
- Added `miss_dense` scenario (sample_every=1): the builder's mutation test showed the miss threshold (`cmp #193`->`#194`) is invisible at sample_every=5 but caught at 1.
- **Known gap:** real joystick/keyboard input is NOT automated (`joyport set` has no effect in headless x64sc). `read_input` was verified once by hand via xdotool (Z=1, X=2, SPACE=4, numpad 4/6/0). Re-test by hand if `read_input` changes.
- gpfdiff lives in factory/tools/ from the start (the ZX backend is the immediate second caller) rather than after it; if the ZX port is dropped, move it back under ports/brickfall-c64/tools/.

## T0013: art + sound polish (2026-10-17)

Sim untouched: the `simulation` section of brickfall.asm is byte-identical to the T0011 version (diffed), `make check` still 11/11 bit-exact x2 + canary.
Presentation lives below the `presentation` banner in `target/brickfall.asm` and only READS the sim. Render/sound temps are `$ef-$fa` + RAM at `$c100-$c125`
(outside gpf_state at `$c000-$c014`); nothing writes `$20-$34`, gpf_state or gpf_bricks. One sim step per 50 Hz frame is unchanged (wait_frame untouched).

Commands: `make -C target check` (sim proof), `make -C target soundcheck` (SID triggers), `make -C target shots` (3 PNGs into `docs/`).

### Layout / art facts
- Memory: code `$0810-~$1100`; charset RAM `$2000` (screen codes 0-63 COPIED FROM CHAR ROM at runtime via `$01`, nothing shipped; our glyphs 64-70 at `$2200`);
  sprites at `$2800/$2840/$2880` (VIC bank 0 sees RAM at `$2000+`; `$1000-$1FFF` is char ROM, which is why the old design had to end below `$1000`). PRG is ~8.4 KB.
- Screen: playfield = char cols 4-35 / rows 0-23 (sprite X=56+x, Y=50+y). Cols 0-2 / 37-39 staggered-brick side panels (brown), cols 3 / 36 grey wall bars, border blue.
  Row 24 = status (score, 3 hearts, mode). Title/OVER/WON messages at rows 10/12/14 (cleared in PLAY). Brick = 4 custom chars (cap, mid, mid, cap), 1 px gap, bottom shade.
- Row colours follow the recipe score ramp: 50 red(2), 40 orange(8), 30 yellow(7), 20 green(5), 10 light blue(14).
- Paddle = TWO x-expanded hires sprites at the same place: sprite 1 white highlight (in front), sprite 2 cyan body with 3 notches marking the 4 bounce zones.
  GOTCHA: lower sprite number wins priority, so the highlight must be the LOWER number (first try had it behind and invisible).
- Ball = 6x6 white disc sprite drawn at (-1,-1) around the 4x4 sim box (purely cosmetic; the sim box is unchanged). Sprite 0 is disabled in OVER (the ball rests at y>192, over the status row).
- Vblank budget (~7000 cycles incl. lines 0-50): sprites are written first; bricks redraw only when the mask changed, messages only when the mode changed; score/hearts every frame.
  The first version redrew all 160 brick cells per frame, which would have crossed into the display area (tearing). Not measured, only budgeted.

### Sound (SID, all from published state of the previous step vs now)
- Voice 1 = ball effects (launch WAIT->PLAY, paddle = vy down->up, wall = vx sign flip between non-zero signs or vy up->down, brick = cleared count changed, pitch from score delta: 50 = E6 ... 10 = D5),
  voice 2 = jingles (miss, game over, win). Later detection overrides earlier on the same voice (brick > paddle > wall).
- Sequence player: `(wave, AD, SR, (freq lo, freq hi, frames)*, 0,0,0)`; each note holds gate for frames-1 then 1 frame gate-off so the next note retriggers; a new event starts 1 frame later
  (gate-off now, first note next tick) - 20 ms latency, accepted. Sustain 0 everywhere, so the decay shapes the envelope.
- BUG caught by soundcheck, worth remembering: `signcls` first used `bmi` right after `ldx lo`, which tests the LO byte's sign: vy=+384 ($0180) read as negative and the paddle bounce never fired. Use `cmp #$80`.
- `tools/soundcheck.sh` probes `$c108-$c10d` (V_IDX/V_TIM/V_WAVE) across scenarios with `gpfdiff probe` and asserts each event started its sequence (launch, paddle, wall, brick rows 0-4, miss, over, win, silence at step 0).
  It proves the TRIGGERS, not the audible result; nobody has listened to it (headless, `+sound`). Needs a human ear for timbre/volume.

### Screenshot tooling (gpfdiff: `shot` and `probe` subcommands, `png.rs`)
- Uses the VICE binary monitor DISPLAY_GET (0x84, fmt 0 = indexed 8-bit) + PALETTE_GET (0x91). Real time (`+warp`), because warp skips frames and the grabbed canvas goes stale.
- VICE 3.10 quirk: reply body is 17 + BL bytes although it announces 21 + BL (the buffer is 4 bytes short). Only the unused bottom-right corner is missing; crop code requires just the rows it needs.
- Reply layout: FL(4)=13, DW(2) DH(2) XO(2) YO(2) IW(2) IH(2) BP(1) BL(4) data. Debug buffer 504x312, inner 320x200 at (136,51). We crop 384x272 at (XO-32, YO-35): the PAL visible area with border.
- PNG writer is dependency-free (stored deflate); upscale is integer nearest-neighbour x3 -> 1152x816. Unit tests: crc32/adler32 known values, scaling, PNG signature.
- Screenshots taken at input points: title = `harness/shot_title.toml` step 100 (idle), play = full_win step 1300, over = game_over step 690. Checkpoint-parked captures at step 0 of boot would race the first frame, hence step 100.
- DEAD END: `-exitscreenshot` / keybuf: the game has no KERNAL IRQ and reads the CIA matrix directly, so VICE keyboard-buffer input cannot drive it; scenario input via the checkpoint is the only automated route.

### Local vision model (advisory; qwen2.5vl:7b installed, llama3.2-vision not checked, nothing pulled)
- Final screenshots, prompt "Is there a paddle, a ball, rows of coloured bricks, and a score? ... list the brick row colours top to bottom": play -> all four present; rows pink, orange, yellow, green, purple.
  title -> all four present; rows red, orange, yellow, green, purple. (5/5 rows distinguished; "purple" is our light blue, a palette-naming quirk.)
- Earlier, an open-ended 6-question prompt reported only 3-4 colours (missed the blue row) and called the paddle "green"/"a simple horizontal bar"; it also read the score "00180" correctly and found hearts and the PLAYING/WAIT text.
  Treat it as a smoke check: it is sensitive to prompt wording. My own read of the PNGs (Read tool) agrees: paddle with white top edge and 3 notches, round ball, 5 distinct rows, readable score/lives/mode.
