# Brickfall — platform-neutral recipe

An original paddle-and-bricks game, designed as a **demo port subject**: no third-party IP,
fully deterministic, small enough for 48K, rich enough that every harness check asserts
something real. There is no original to diff against, so the oracle is the Rust reference
model in `model/` (T-task "reference model"); every port is diffed against *its* traces.

## Rules (integer-only, no RNG, no floating point)

Logical playfield is **256 x 192 px**, origin top-left (Spectrum-native; C64 centres it in
320x200 with a border). All positions are pixels; ball position carries 8 fractional bits
(8.8 fixed). One simulation step = one 50 Hz frame; ports run it at their own frame rate
via a fixed-step accumulator so traces compare **per step, not per wall-clock second**.

| Thing | Value |
|---|---|
| Bricks | 8 columns x 5 rows, each 32x8 px, top-left at (0, 24); bit `row*8+col` of a 40-bit mask, 1 = present |
| Paddle | 32x8 px, y = 176, x in [0, 224]; moves 4 px/step on LEFT/RIGHT, clamped |
| Ball | 4x4 px box, 8.8 position; velocity (vx, vy) in 8.8 px/step |
| Lives / score | 3 lives; brick score = 50 - 10*row  (top row 50 ... bottom row 10) |
| Launch | Ball sits on paddle (state WAIT). FIRE launches: vy=-0x0180 (-1.5), vx = -0x0080 if LEFT held, +0x0080 if RIGHT held, else 0 |
| Walls | Left/right/top reflect the matching velocity component; ball clamped inside |
| Paddle bounce | Ball bottom reaches y=176 while overlapping paddle in x: vy = -|vy|; vx set by 8px zone of hit: zones 0..3 -> vx = -0x0180, -0x00C0, +0x00C0, +0x0180 |
| Brick hit | First brick overlapped this step (scan row-major) is cleared, score added, **vy sign flips**; at most one brick per step |
| Speed-up | After every 10th brick cleared, |vy| += 0x0040 (max 0x0300) |
| Miss | Ball top > 192: lives -= 1; lives==0 -> state OVER, else state WAIT |
| Win | Bricks mask == 0 -> state WON |

Reduction decisions (so ports don't reinvent them): no brick-side collision distinction
(always a vertical flip); no power-ups; no levels; one brick per step; fixed zone table
instead of angle math. Cut with reason: each removed feature multiplies test cases per
target while adding nothing to what the demo proves.

## State contract (the harness interface)

Every port exports an assembler label **`gpf_state`** pointing at this 16-byte
little-endian block, updated at the end of every simulation step. The harness finds it
through the assembler's symbol output, so the address is not hard-coded anywhere.

| Off | Size | Field |
|---|---|---|
| 0 | 2 | `step` — simulation steps since boot/reset |
| 2 | 1 | `mode` — 0 WAIT, 1 PLAY, 2 OVER, 3 WON |
| 3 | 1 | `lives` |
| 4 | 2 | `score` |
| 6 | 1 | `paddle_x` |
| 7 | 1 | `cleared` — bricks cleared so far |
| 8 | 2 | `ball_x` (8.8) |
| 10 | 2 | `ball_y` (8.8) |
| 12 | 2 | `ball_vx` (signed 8.8) |
| 14 | 2 | `ball_vy` (signed 8.8) |

Brick mask is a second block `gpf_bricks` (5 bytes, little-endian bit order above).

## Input contract

Scripted input is a list of `(step, buttons)` with buttons a bitmask: 1 LEFT, 2 RIGHT,
4 FIRE. The ports read keys/joystick normally; the harness injects them through the
emulator, so no test-only code path ships in the build.

## Acceptance (what "done" means for a port)

1. For each scenario in `scenarios/*.toml`, the port's `gpf_state` trace matches the
   reference model's golden trace **at every sampled step** (exact match, all fields).
2. Scenarios cover: launch left/centre/right, each paddle zone, wall bounces, a miss,
   game over, a speed-up step, a full win, and a paddle clamp at both edges.
3. Harness passes twice in a row (determinism gate — recipe
   `a-behavioural-diff-harness-must-be-proven-deterministic-before-its-diffs-are-believed`).

Art, sound and presentation are **per target** and unverified by the trace; they get a
screenshot-readability check (local vision model) rather than a diff.

## Resolved ambiguities

Choices made by the reference model (`model/src/lib.rs`); ports must match them.

- **Step counter**: `step` is incremented first on every call (also in OVER/WON). Initial state is step 0; the first `step()` call yields step 1. Scenario input index `i` drives the call that produces step `i+1`.
- **Initial state**: WAIT, lives 3, score 0, paddle_x 112, cleared 0, all 40 bricks, velocity 0.
- **Ball on paddle (WAIT)**: ball_x = (paddle_x + 14) << 8 (centred), ball_y = 172 << 8 (bottom touches paddle top); re-attached every WAIT step after the paddle moves, velocity 0.
- **Order within a step**: paddle move (LEFT/RIGHT, both held cancel, clamp 0..224) -> WAIT: re-attach, FIRE launches (ball does not move on the launch step; launch direction uses the same step's LEFT/RIGHT) -> PLAY: move ball, walls, paddle, bricks, then win/miss. OVER and WON freeze everything except `step`.
- **Walls**: ball x clamped to [0, 252<<8] (252 = 256-4) and vx set to +|vx| / -|vx|; top: y clamped to 0, vy = +|vy|. No bottom wall.
- **Overlap tests** use integer pixels (position >> 8) and strict inequalities: boxes overlap iff `bx < r && bx+4 > l && by < b && by+4 > t`.
- **Paddle hit**: requires vy > 0, `(y>>8)+4 >= 176`, `(y>>8) < 184` and x overlap with paddle box [px, px+32). Then y = 172<<8, vy = -|vy|. Zone = clamp(ball_centre_x - paddle_x, 0, 31) >> 3, where centre = (x>>8)+2; vx = zone table.
- **Brick hit**: tested after the paddle, with the post-wall/paddle position; vy = -vy (plain negation, whatever its sign); the ball is not repositioned. Score = 50 - 10*row.
- **Speed-up**: applied in the same step as the 10th/20th/30th/40th brick, after the vy flip, preserving sign: |vy| = min(|vy|+0x40, 0x300).
- **10th-brick-is-last**: with 40 bricks the 40th clear still speeds up, then mode becomes WON (win is checked before miss).
- **Miss**: `(y>>8) > 192`. lives -= 1. lives == 0 -> OVER with ball velocity zeroed and ball left where it fell; otherwise WAIT with ball re-attached to the paddle, vx=vy=0.
- **Relaunch speed**: launch always sets vy = -0x0180, so speed-ups are lost on a miss; `cleared` carries over, so the next speed-up is still at the next multiple of 10.
- **Scenario format** (`scenarios/*.toml`): `steps`, `sample_every`, `[[input]] step, buttons`. Buttons hold from `step` until the next entry (initially 0). Trace lines are printed for every state whose `step % sample_every == 0`, including step 0.
- **Trace line**: `step mode lives score paddle_x cleared ball_x ball_y ball_vx ball_vy bricks_hex`, decimal (ball_x/y raw 8.8, vx/vy signed 8.8); bricks_hex = the 5 `gpf_bricks` bytes in memory order, 2 hex digits each.
