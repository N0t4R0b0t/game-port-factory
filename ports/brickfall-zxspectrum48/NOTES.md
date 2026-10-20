# Brickfall

`c64` -> `zxspectrum48`

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

## T0008: ZX48 build + MAME gpfdiff backend (2026-10-17)

Verify: `make -C ports/brickfall-zxspectrum48/target check` (~20 s: 11 scenarios x2 + canary),
`make -C ports/brickfall-zxspectrum48/target smoke-keys` (read_input via MAME's keyboard matrix),
`cargo test --offline --manifest-path factory/tools/gpfdiff/Cargo.toml` (31 tests).
Result: 11/11 scenarios bit-exact against the model's golden traces, each run twice (fresh MAME each),
on the first run of the Z80 sim: no sim/model disagreement was found.

Files: `target/{brickfall.asm,Makefile,keys_smoke.lua}`, `factory/tools/gpfdiff/{src/mame.rs,lua/gpf_mame.lua}`.

### Z80 build facts
- sjasmplus: `--sym=brickfall.sym` gives `name: equ 0x0000F000` lines (there is no `--lbl`). `SAVESNA "x.sna", start` in the source
  writes a 48K SNA. `DEVICE ZXSPECTRUM48` is needed for SAVESNA. sjasmplus option errors print as "Unrecognized option".
- Map: code $8000.. (asserted < $F000); gpf_state $F000, gpf_bricks $F010, work copy $F020-$F034, temps $F040-$F047;
  IM2 table $FC00-$FD00 (all $FD) + ISR at $FDFD (`ei; reti`); stack $FFF0. Clear of screen ($4000-$5AFF) and sysvars.
- Frame sync: `halt` once per step, IM 2 with a trivial ISR (no ROM ISR, so no IY/sysvar dependence). Sim state never depends on timing.
- `gpf_input_ret` is the `ret` of read_input (A already loaded). 8.8 math with 16-bit `add hl,de` / `sbc hl,de`; same carry-based sign logic as the 6502.
- Keys: Z or Q = left, X or A = right (the spec said "Q/A or Z/X"; taken literally as two alternative pairs, Q/A as left/right is
  unusual and is a design call for the top tier), SPACE fire, Sinclair joystick 2 = keys 6 left / 7 right / 0 fire.
  Kempston deliberately NOT read: on a plain 48K port $1F floats and returns screen data (phantom input).
- Rendering: bricks = attribute cells only (paper colour per row, alternate bright per column, 4 cells wide, char rows 3-7); ball (4x4) and paddle
  (32x8) are XOR-drawn bitmaps, erased by XOR-ing at the previous position (PREV_*); ball not drawn when y > 188 (would leave the bitmap).
  (SUPERSEDED by T0009 below: bricks are now bitmap, HUD text added, render has a verifier.)
- The sim is ~1.2 KB; one step + render fits easily in a 20 ms frame.

### MAME facts (0.289) - what the backend learned
- Machine `spectrum`; the romset is NOT in `~/.mame/roms` (only coco2b there). `mame -verifyroms spectrum` reports "NOT FOUND". The Makefile uses
  `$(ZX_ROMPATH)`, falling back to the dizzy-coco2 port's spectrum.zip (the user's own ROM, read-only, via `-rompath`). verifyroms still says
  "testromv037.bin NOT FOUND" for that zip: that is an optional diagnostic ROM, the machine runs fine.
- `-snapshot x.sna` loads within ~4 frames and sets PC; no tape/boot delay. (Savestates, by contrast, are version-tied: see dizzy harness notes.)
- Breakpoints need `-debug`; `-debugger none` keeps it from opening a Qt window. With `-video none` + `-nothrottle` a 3972-step scenario takes ~3 s.
  `-noreadconfig` stops ~/.mame cfg from affecting results.
- Lua: `cpu.debug:bpset(addr,"","")` stops the CPU BEFORE the instruction at addr. `emu.register_periodic` callbacks keep firing while the CPU is
  stopped, with `manager.machine.debugger.execution_state == "stop"`; set it to "run" to resume. The initial -debug stop at PC $33B1 is
  ignored by checking PC == gpf_input_ret.
- IPC (documented in the header of mame.rs and gpf_mame.lua): Lua prints `GPF S <42 hex>` at each hit and BLOCKS on `io.stdin:read("l")`; gpfdiff answers
  `B <n>`; Lua writes `cpu.state["A"].value = n`, prints `GPF ACK <A> <PC>` read back after the write, and resumes. `Q` exits. Blocking in the
  callback means MAME is parked while the harness thinks, so there is no timing dependence; the ACK check (A matches, PC == gpf_input_ret) is the
  "did the write take" gate, and the core's step==i check catches any missed/doubled hit.
- Real keyboard input is NOT injected via xdotool: DEAD END: under Xvfb with `-video soft -window`, xdotool key events (with and without
  windowfocus, no WM) never reached the emulated keyboard (paddle_x stayed 112). It is also unnecessary: `manager.machine.ioport.ports[":LINEn"].fields[...]:set_value(1)`
  presses a key in the emulated matrix with no X11 (this is what `make smoke-keys` uses; all 8 keys PASS, including SPACE and Sinclair 0 fire).
  Field-name prefixes are `"z "`, `"SPACE"`, `"0 "`... (names are long, e.g. "z    Z    :      LN ..."), match by prefix.

### Harness mutation tests (scratch builds under target/build/mut, each vs all 11 scenarios)
| Mutation | Caught by |
|---|---|
| speed-up `ld de,$40` -> `$41` | full_win, speedup, wall_bounces (step 1140 ball_y) |
| paddle top `cp 172` -> `173` | full_win, launch_centre, paddle_zones, speedup, wall_bounces |
| miss threshold `cp 193` -> `194` | game_over (step 590), miss_dense (step 161 mode); NOT miss_then_wait (sample_every=5 hides it, as on C64) |
| brick column threshold `cp 29` -> `30` | full_win, wall_bounces (step 2400) |
| row-0 score 50 -> 51 | full_win, wall_bounces |
| zone table entry $FF40 -> $FF41 | full_win, paddle_zones, speedup, wall_bounces |
| paddle right clamp 224 -> 223 | full_win, paddle_clamp_edges, paddle_zones, speedup, wall_bounces |
Plus the canary in `make check` (mutated golden line must fail with `step 10 ... field ball_vx: expected 1 got -128`).

## Review notes (top tier, 2026-10-17)
- Independently re-ran: ZX check (~20 s, 11 scenarios x2, canary ok), gpfdiff 31/31, C64 check still PASS after shared-trait change.
- **ROM:** the Spectrum ROM is not distributed here. Supply your own `spectrum.zip` (MAME romset, single `spectrum.rom`) in `~/.mame/roms` or set `ZX_ROMPATH`. A machine-specific fallback into a private repo was removed from the Makefile before release.
- **Keys:** left = Z or Q, right = X or A, fire = SPACE, plus Sinclair joystick 2 (6/7/0). Kempston omitted (port $1F floats on a plain 48K). Q/A as a left/right pair is unusual; confirm or change.
- `gpf` cannot edit a task's verify string (tasks.toml edited by hand) -- factory friction, filed as a task.

## T0009: ZX48 art + sound polish (2026-10-17)

Verify: `make -C ports/brickfall-zxspectrum48/target check` (sim untouched, 11 scenarios x2 + canary) and
`make -C ports/brickfall-zxspectrum48/target check-render` (cadence + sound + screen integrity, ~15 s).
Screenshots: `make -C ports/brickfall-zxspectrum48/target shots` -> `docs/screenshot-play.png`, `docs/screenshot-over-or-title.png`
(byte-reproducible; MAME snapshot 352x296 scaled 3x nearest-neighbour via ImageMagick `magick -strip -filter point`).
The sim section of brickfall.asm is byte-for-byte unchanged; render/sound only read W_*/gpf_state and write the screen,
port $FE and their own vars at $F050-$F092 (R_*, S_PREV, SND_*). Main loop gained one `call snd_init` and one `call sound`.

### Attribute-clash technique and its trade-off
- Rule: paper is black in every cell; only INK carries colour. Sprites are pixels only, so no sprite draw ever writes an attribute,
  and a sprite can never change the look of a neighbouring cell. Cost: a sprite takes the ink of the cell it is in (ball is white
  in the open field, yellow/cyan/etc. while inside a brick-row or paddle-row cell, and the ink-coloured parts of a brick turn black
  where the ball overlaps: one or two frames at a hit). No per-pixel colour, no multicolour sprites.
- Bricks: 4 cells x 1 cell, aligned to the sim's 32x8 bricks at char rows 3-7 (y 24..63). Alignment is exact: the sim's hit window
  (ball top y in 21..31 for row 0, col = x>>5) equals "4x4 ball touches the drawn pixels". Pixels = solid ink with a 1 px gap right and
  bottom (separates neighbours, so no alternating-bright trick is needed). Ink per row, top (50 pts) to bottom (10 pts): bright red,
  yellow, green, cyan, magenta. Drawn once at start; a dead brick is cleared (4 cells of bitmap + attribute back to $47).
- HUD: row 0, ROM font read from $3D00 (own copy of nothing, just reads the machine ROM): `SCORE nnnnn` yellow, `LIVES n` green;
  blue rule line at y=16; centred 16-cell message on char row 14 (`SPACE: LAUNCH` cyan / `GAME  OVER` red / `YOU  WIN` green).
  The ball can pass through HUD/message cells (the sim's top wall is y=0, the field spans the whole 256 px, so there is no pixel
  frame to draw inside it); this is clean because of the ordering rule below. Frame = blue border (`out ($FE),1`); the border cannot be bright.
- Paddle: 32x8 pixels with rounded ends, bright cyan (row 22 attributes), x is always a multiple of 4 (sim moves 4 px from 112).
  Ball: 4x4 round-ish pixels.
- Ordering rule (the one real gotcha): XOR draws commute, but brick/text writes are NOT XOR. So a frame is: (1) erase the ball by
  XOR, (2) write bricks/text, (3) paddle XOR, (4) draw the ball by XOR. Writing text while the ball is drawn leaves 4-pixel debris
  when the ball is later erased. `render_check.lua` counts pixels at GAME OVER to catch this.
- Tear/flicker: all redraw happens right after HALT, while the beam is still in the top border (first pixel line is ~14000 T after
  the interrupt; sim+render is ~10000 T worst frame). Only moved things are touched: ball when it moved or something changed under
  it, paddle only when px changed, bricks/text only when W_BRK/score/lives/mode differ from R_BRK/R_*. Not measured on real hardware.

### Sound (beeper)
- Events are inferred by diffing the published gpf_state against last frame's copy (S_PREV): `cleared` changed -> brick (row = first
  changed brick byte, pitch rises toward row 0), mode WAIT after PLAY -> miss, mode -> OVER / WON, vy sign flip in PLAY -> paddle
  (now up) or top wall (now down), vx sign flip -> side wall. Priority = effect id (brick > paddle > walls; miss/over/win highest),
  an effect is only pre-empted by an equal or higher id. WAIT->PLAY launch is silent.
- One slice per frame, 28000 T (square wave, `13*delay+45` T per half-period, count clamped to 255), then back to work; effects of
  2-14 frames chain slices (tone sequence tables ending in 0). Timing margin measured with mutants: SLICE_T=50000 already breaks the
  cadence (2 lost frames in the GAME OVER run), 28000 does not; ~22000 T of headroom.
- Keep the slice under about 40000 T or a frame is lost (an interrupt arriving mid-slice makes the next HALT wait a whole extra frame).
  The sim is unaffected either way (it is frame-count based, only the speed would change), but `check-render` fails on it.
- `check-render` (render_check.lua, real emulated keys, a tracking bot): (1) published step advances exactly 1 per frame for the whole
  run; (2) effect ids seen: brick, paddle, miss, game over (over run) and brick, paddle, win (win run); (3) at GAME OVER/WIN: brick
  pixel count = 217 x live bricks (+12 for the frozen ball on WIN), paddle row = 244 px, empty field rows all zero. It does not judge
  how the sounds *sound*; MAME runs with `-sound none`. Pitch/duration are by calculation only, never listened to.

### Dead ends / decisions
- Attribute-coloured (paper) bricks, the original T0008 approach: needed alternating bright to separate neighbours and gives no
  bitmap to draw a gap in. Replaced by ink+bitmap bricks with a pixel gap.
- Attribute-based sprite colour (e.g. recolouring cells under the ball): rejected, it is exactly what causes clash on neighbouring
  bricks/paddle; the trade-off above is deliberate.
- Sound ternary in sjasmplus (`a ? b : c`) is not supported; use DEFL + IF. `jr` ranges in draw_bricks overflowed after growth: use jp.
- MAME snapshot works under `-video none` (file lands in `-snapshot_directory/<machine>/0000.png`); no X11 needed. Calling
  `manager.machine:exit()` does not stop the current Lua callback: guard with a flag or it keeps printing.
- Vision model readability (advisory only, qwen2.5vl:7b via ollama /api/generate, temperature 0): play shot -> paddle yes (light blue bar),
  ball yes (small white dot, centre), brick rows red/yellow/green/cyan/magenta (correct), score 00120 (correct), LIVES 3 (correct).
  GAME OVER shot -> bricks/colours, score 00200, LIVES 0 correct, but it claimed a ball "at bottom centre": there is none (ball is hidden
  by design after a miss); it most likely mistook the paddle. It also did not mention the GAME OVER text. Treat as advisory; the
  author's own look at the PNGs agrees with the first and not with that ball claim.
- Only the SNA is built; no tape/TAP. The `.sna` is gitignored (repo-wide rule).

## Black-box mode: this port as the stand-in "unknown original" (gpfdiff oracle mode, part B)

Verify: `make -C ports/brickfall-zxspectrum48/target check-blackbox` (~30 s), `make -C ports/brickfall-coco2/target check-live-blackbox` (~35 s).
Files: `blackbox/harness.toml` (the black-box manifest: NO gpf_state / gpf_input_ret / symbol file, raw addresses), `blackbox/harness.bad{gate,key}.toml`
(negative tests), `factory/tools/gpfdiff/{src/keys.rs,src/keysrun.rs,src/watch.rs,lua/gpf_keys.lua}`.

### Findings (durable)
- Raw addresses used by the black-box map (the same as brickfall.sym, written as literals): step $F000 (2), mode $F002, lives $F003, score $F004 (2),
  paddle_x $F006, cleared $F007, ball_x $F008 (2, 8.8), ball_y $F00A (2), ball_vx $F00C (2, signed), ball_vy $F00E (2, signed), bricks $F010 (5, hex).
  Copies of the published state exist: the working copy $F020.. and `PREV_*` $F045..$F047 (last drawn ball/paddle), plus a further copy at $F070.. (origin not investigated); they move in the
  same frames, so `gpfdiff watch` cannot tell them apart by behaviour.
- Ready gate: `$F046` (PREV_BY, the ball's last-drawn row) is 255 until the first render and then 172; `ready = { addr = 0xF046, in = [1, 254] }`.
  First true at MAME frame_done hook 6 with step 0: the program is idle at its `halt` and no simulation step has run. Found with `watch --no-gate`.
- Frame clock (hook log of the unmodified game, `Z` applied at the end of hook 6): hook 7 already shows step 1 and paddle 108. A key applied at the end of hook `t` is
  honoured by the program's very next frame (it polls the matrix once per frame after `halt`), so `[time] input_latency_frames` is 0. Mechanism, not tuning;
  at knob 1 the scenarios whose first input is at frame 0 are rejected by the harness, and the fake-MAME tests show a one-frame latency failing at 0 and passing at 1.
- The startup costs frames (observed per hook): RAM is still zero at hook 3 (snapshot being loaded), lives = 3 and PREV_BY = 255 (nothing drawn) at hooks 4 and 5,
  the ball is drawn (PREV_BY = 172) and the program idles at its `halt` at hook 6; the first sim step is in frame 7. **A gate on `lives == 3` ($F003) starts the timeline at hook 4, two frames early, so every
  sample is 2 steps behind the golden** (`MISMATCH step 5 (sample #1) field step: expected 5 got 3`). The gate must be "first frame drawn", not "data initialised".
- 11/11 black-box captures equal `games/brickfall/recipe/golden/*.trace` at every sample (modulo `#` lines), each captured twice (identical) and a second capture identical to the first.
  The CoCo port (cooperative, 60 Hz) passes 11/11 against the black-box ZX manifest as a LIVE oracle.
- `watch --region 0xF000:0xF0FF --keys "LEFT@0ms+1000ms" --frames 60` reports `0xF006  70 -> 00 (112 -> 0) x28 frames` (paddle x, 4 px per frame, clamps at 0 after 28 frames).

### Dead ends / decisions
- A gate on `lives` (or any "initialised" byte) looks right and is wrong by two frames: see above. Re-derive the gate with `watch --no-gate` for any new original.
- Reading RAM per frame with `mem:read_u8` in a loop is fine for a few bytes; for `watch` regions `mem:read_range(a, b, 8)` returns the whole range as a string (42 KB per frame costs under 1 ms).
- `emu.register_frame_done` fires under `-video none`; no `-debug` is needed for keys mode (do not pass it: it stops the machine at the first instruction).
