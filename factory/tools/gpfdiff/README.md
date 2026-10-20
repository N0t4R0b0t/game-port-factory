# gpfdiff

A trace differ for game ports. It drives an emulator one simulation step at a time through a
scripted scenario, reads a small block of the port's RAM (`gpf_state`) at every step, and
compares what it read with a golden trace. The golden trace is the oracle.

- The golden traces come from a reference model (Rust, platform neutral) in `games/<game>/recipe/`.
  There is no original game to diff against for Brickfall, so the model is the truth.
- A port passes when every sampled line of its trace equals the golden line, exactly, in every field.
- Each scenario is run N times (default 2), each time in a fresh emulator. The runs must be identical
  to each other before any golden diff is believed (determinism gate).
- The oracle can also be a **recorded trace** (`gpfdiff capture`) or **another port run live** (`[oracle]`, see
  "Oracle sources"); the state read from the port is a **field map** (see "Field maps"), by default the 11 Brickfall
  columns. Differences can be declared as named, reasoned **expected deviations** (verdict EXPECTED, exit 0).
- A built-in canary mutates one golden line in memory and demands the comparison reject it. A harness
  that cannot fail is reported as a harness error.
- Nothing is injected into the port: scripted buttons are written into the CPU's `A` register at the
  `ret` of `read_input`, so no test-only code ships in the build.
- A program that was **not written to cooperate** (an original: no `gpf_state`, no breakpoint label, nothing exported)
  is driven in **keys mode**: it runs free, keys are pressed through the emulator's own keyboard matrix on a frame clock,
  and its state is read from raw RAM addresses (see "Keys mode (black-box)"). `gpfdiff watch` finds those addresses.

Rust, std plus `clap`. Builds offline: `cargo build --release --offline --manifest-path factory/tools/gpfdiff/Cargo.toml`.
Binary: `factory/tools/gpfdiff/target/release/gpfdiff`.

## Quick start

```bash
gpfdiff doctor --platform all                 # what is installed, what is missing (installs nothing)
make -C ports/brickfall-c64/target check      # build + gpfdiff check .. (c64)
gpfdiff check ports/brickfall-zxspectrum48    # needs the port built first (make -C <port>/target all)
make -C ports/brickfall-coco2/target check    # build (lwasm) + gpfdiff check .. (coco2, MAME coco2b)
make -C ports/brickfall-zxspectrum48/target check-blackbox   # the ZX port as an UNKNOWN ORIGINAL: capture == golden, watch, negative tests
make -C ports/brickfall-coco2/target check-live-blackbox     # CoCo port checked against that black-box original, live
gpfdiff watch ports/brickfall-zxspectrum48/blackbox --keys "LEFT@0ms+1s"   # which RAM bytes move when LEFT is held?
```

Platforms:

| `platform` | Emulator | Image | Symbol file | Input register | Your own ROM |
|---|---|---|---|---|---|
| `c64` | x64sc (VICE), binary monitor over TCP | `.prg` | acme `--vicelabels` | 6502 `A` | none (VICE ships its own) |
| `zx48` | MAME `spectrum`, Lua script | `.sna` snapshot (`-snapshot`) | sjasmplus `--sym` | Z80 `A` | `spectrum.zip` (`$ZX_ROMPATH`) |
| `coco2` | MAME `coco2b`, Lua script | DECB `.bin`, written into RAM by the script | lwasm `--map` | 6809 `A` | `coco2b` (`$COCO_ROMPATH`) |

## Architecture

```
  recipe/scenarios/NAME.toml ----+
  recipe/golden/NAME.trace  ----+|          harness.toml (platform, image, labels, recipe)
                                ||                        |
                                vv                        v
                     +-----------------------------------------------+
                     | core: runner.rs / target.rs / diff.rs         |
                     |   run_scenario(): for each input point i      |
                     |     read_state -> step == i ? (else desync)   |
                     |     sample if i % sample_every == 0           |
                     |     provide_input(buttons_at(i))              |
                     |   compare_runs(): determinism, then golden    |
                     +-------------------+---------------------------+
                                         | trait Target
                    +--------------------+--------------------+
                    | c64.rs                                  | mame.rs (+ lua/gpf_mame.lua; coco.rs)
                    | VICE binary monitor over TCP            | MAME + Lua script over stdin/stdout
                    v                                         v
                  x64sc (under xvfb-run)                    mame (-debug, -video none): zx48, coco2
                    |                                         |
                    +---------> program parked at gpf_input_ret <---------+
                                reads gpf_state (16 B) + gpf_bricks (5 B)
```

Oracle-mode modules: `fields.rs` (field map: where each column is read from, scale/offset/tolerance), `expect.rs`
(`expectations.toml`, PASS/EXPECTED/FAIL verdicts, stale detection), `capture.rs` (`gpfdiff capture`).
Keys mode: `keys.rs` (time axis, key names, plan: pure logic), `keysrun.rs` (MAME process + `lua/gpf_keys.lua`),
`watch.rs` (`gpfdiff watch`, change de-noising). Keys mode is a second, free-running path next to the `Target` trait
(`runner::run_traces` picks it when the manifest says `[input] mode = "keys"`); `capture`, `check` and live oracles use it unchanged.
Other modules: `coco.rs` (CoCo pure logic: lwasm map parser, DECB parser, load list), `check.rs` (the `check` command and canary), `report.rs` (table, diff context, JSON,
colour), `doctor.rs` (prerequisites, ROM search, pre-flight), `errors.rs` (error classification and
exit codes), `manifest.rs` (`harness.toml`), `scenario.rs`, `trace.rs`, `state.rs`.

## The state contract

Every port exports three assembler labels, found through the assembler's symbol file (no hard-coded
addresses):

| Label | Meaning |
|---|---|
| `gpf_state` | 16-byte little-endian block, rewritten at the end of every simulation step |
| `gpf_bricks` | 5-byte brick mask (Brickfall) |
| `gpf_input_ret` | the `RTS`/`ret` of `read_input`; the emulator stops here BEFORE it executes, so the value harness writes into `A` is what `read_input` returns |

The field layout of `gpf_state`, the input bitmask (1 LEFT, 2 RIGHT, 4 FIRE) and every resolved
ambiguity are specified in **`games/brickfall/recipe/README.md`**, sections "State contract", "Input
contract" and "Resolved ambiguities". `src/state.rs` decodes it. Symbol file formats: acme
`--vicelabels` (`al C:c000 .gpf_state`) for c64, sjasmplus `--sym` (`gpf_state: equ 0x0000F000`) for zx48, lwasm `--map` (`Symbol: gpf_state (brickfall.bin) = 1000`) for coco2.

## File formats

Scenario (`recipe/scenarios/NAME.toml`). Buttons hold from `step` until the next entry (initially 0).
Input index `i` drives the simulation call that produces step `i+1`. Max buttons value is 7.

```toml
steps = 300          # input points 0..=300
sample_every = 5     # trace a line when step % 5 == 0 (step 0 included)
[[input]]
step = 0
buttons = 5          # LEFT + FIRE from step 0
[[input]]
step = 10
buttons = 0
```

The same file may be authored in **milliseconds** (backward compatible; each key in its own unit, so the two forms can be
mixed): `length_ms` instead of `steps`, `sample_every_ms` instead of `sample_every`, and in an `[[input]]` `at_ms` instead
of `step`, plus `duration_ms` (the buttons are released that long after `at_ms`; an entry at that instant wins) and
`press = ["LEFT", "FIRE", "Q"]` (names; `LEFT`/`RIGHT`/`FIRE` are the bits 1/2/4 of `buttons`, any other name is a key
of the target and needs keys mode):

```toml
length_ms = 6000
sample_every_ms = 100
[[input]]
at_ms = 0
press = ["LEFT", "FIRE"]
duration_ms = 200
```

A step is `step_ms` milliseconds (`[time] step_ms`, default 20), so `step = N` means `at = N * step_ms` ms. Cooperative
targets run the step view (ms rounded to the nearest step, halves up), keys mode runs the millisecond view (see "Time axis").

Golden trace (`recipe/golden/NAME.trace`). One line per sampled step, whitespace-separated columns,
`#` comments and blank lines ignored. **Without a header** the file is the legacy 11-column layout
`step mode lives score paddle_x cleared ball_x ball_y ball_vx ball_vy bricks` (validated strictly: the first ten are
decimal, ball position raw 8.8, velocities signed 8.8; `bricks` is 10 hex digits). Existing goldens have no header and
are read unchanged. **With a header line `# columns: a b c`** (before the first sample) the file is self-describing and
carries any columns; every value is normalised text (see "Field maps"). `gpfdiff capture` always writes the header.

```
0 0 3 0 112 0 32256 44032 0 0 ffffffffff
5 1 3 0 108 0 30720 42496 -128 -384 ffffffffff
```

## harness.toml reference

One per port, next to `PORT.toml`. A small TOML subset (strings, integers incl. `0x..`/`$..`, floats, `true`/`false`, string arrays; the tables
`[emulator]`, `[state]`, `[oracle]`, `[input]`, `[input.keys]`, `[time]`, `[boot]` and any number of `[[field]]`; `ready = { addr = 0x.., eq = 1 }` is the one
inline table). Top-level keys go before the first table.
Unknown keys are errors. Relative paths are relative to the file.

| Key | Required | Meaning |
|---|---|---|
| `platform` | yes | `c64`, `zx48` or `coco2` |
| `image` | yes (or `[boot] image`) | program image: `.prg` (c64), `.sna` (zx48) or DECB `.bin` (coco2) |
| `labels` | yes, except keys mode | symbol file from the assembler |
| `recipe` | yes for `check`/`capture` (a keys-mode manifest used only by `watch` may omit it) | directory holding `scenarios/*.toml` and `golden/*.trace` (same file stem) |
| `expectations` | no | path of the expectations file (default `expectations.toml` next to the manifest; an explicit path must exist) |
| `[state]`, `[[field]]` | no (yes in keys mode) | field map instead of the built-in columns, see "Field maps" |
| `[input]`, `[input.keys]`, `[boot]`, `[time]` | no | keys mode: black-box driving, ready gate, time axis; see "Keys mode (black-box)", "Boot and the ready gate", "Time axis" (`[time] step_ms` also applies to cooperative targets) |
| `[oracle]` | no | where the expected trace comes from, see "Oracle sources" |
| `repeat` | no | runs per scenario, default 2 |
| `timeout` | no | seconds to wait for the emulator at each step, default 30 |
| `required_labels` | no | labels that must exist, default `["gpf_state", "gpf_bricks", "gpf_input_ret"]` (none in keys mode) |
| `[emulator] x64sc` | no | x64sc name or path (default `x64sc`) |
| `[emulator] xvfb` | no | `auto` (default: use `xvfb-run` if installed), `always`, `never` |
| `[emulator] mame` | no | MAME name or path (default `mame`) |
| `[emulator] machine` | no | MAME machine (default `spectrum` for zx48, `coco2b` for coco2) |
| `[emulator] rompath` | no | MAME `-rompath` (`;`-separated) |

Precedence for every emulator setting: command-line flag, then (for the ROM only) `$ZX_ROMPATH` (zx48) or
`$COCO_ROMPATH` (coco2), then `harness.toml`, then the default. The ROM falls back to `~/.mame/roms`.

```toml
platform = "c64"
image    = "target/brickfall.prg"
labels   = "target/brickfall.vs"
recipe   = "../../games/brickfall/recipe"
repeat   = 2
```

See `ports/brickfall-c64/harness.toml`, `ports/brickfall-zxspectrum48/harness.toml` and `ports/brickfall-coco2/harness.toml`.

## Commands

### doctor

`gpfdiff doctor [--platform c64|zx48|coco2|all] [--rompath DIR]`. Checks every prerequisite and prints the
install command for each missing one for Arch, Debian/Ubuntu and macOS. It never installs anything.
The Spectrum ROM is your own and is never distributed: put `spectrum.zip` (MAME `spectrum` romset, one
file `spectrum.rom`) in `~/.mame/roms`, or set `$ZX_ROMPATH`, or pass `--rompath`. Exit 0 if every
REQUIRED item is present, 2 otherwise. OPTIONAL items never change the exit code.

Real output (ROM deliberately not supplied):

```
gpfdiff doctor (platform: all); checks only, installs nothing

[common]
  [OK      ] cargo         cargo 1.94.1 (29ea6fb6a 2026-03-24) (~/.cargo/bin/cargo)
  [OK      ] magick        Version: ImageMagick 7.1.2-31 Q16-HDRI x86_64 8309dc92a:2026 (/usr/bin/magick)

[c64]
  [OK      ] x64sc         x64sc (VICE 3.10) (/usr/bin/x64sc)
  [OK      ] acme          This is ACME, release 0.97 ("Zem"), 11 Jul 2025 (/usr/bin/acme)
  [OK      ] xvfb-run      /usr/bin/xvfb-run
  [OK      ] c1541         /usr/bin/c1541

[zx48]
  [OK      ] mame          0.289 (mame0289-dirty) (/usr/bin/mame)
  [OK      ] sjasmplus     SjASMPlus Z80 Cross-Assembler v.20190306.1 (~/.local/bin/sjasmplus)
  [MISSING ] spectrum ROM  MAME `spectrum` romset (your own; never distributed)
             fix: supply your own: put spectrum.zip (MAME `spectrum` romset, one file spectrum.rom) in ~/.mame/roms, or set $ZX_ROMPATH / pass --rompath

MISSING required: spectrum ROM
```

The CoCo ROMs are your own too: put `coco2b.zip` (MAME `coco2b` romset: `bas13.rom` + `extbas11.rom`; a `coco2b/`
folder of the two files works as well) in `~/.mame/roms`, or set `$COCO_ROMPATH`, or pass `--rompath`.

Real output for `gpfdiff doctor --platform coco2` (ROM present, then with `COCO_ROMPATH=/nonexistent`):

```
[coco2]
  [OK      ] mame          0.289 (mame0289-dirty) (/usr/bin/mame)
  [OK      ] lwasm         lwasm from lwtools 4.24 (/usr/bin/lwasm)
  [OK      ] coco2b ROM    coco2b romset under ~/.mame/roms
...
  [MISSING ] coco2b ROM    MAME `coco2b` romset (your own; never distributed)
             fix: supply your own: put coco2b.zip (MAME `coco2b` romset: bas13.rom + extbas11.rom) in ~/.mame/roms, or set $COCO_ROMPATH / pass --rompath
```

Tools: required = cargo; c64: x64sc, acme; zx48: mame, sjasmplus, the ROM; coco2: mame, lwasm, the ROM. Optional = magick (only
`make shots` on zx48), xvfb-run (without it x64sc opens a window on your desktop), c1541.

### check

`gpfdiff check <port-dir> [--manifest FILE] [--only a,b] [--list] [--repeat N] [--json] [--no-canary] [--fail-fast|--keep-going]
[--timeout S] [--debug] [--x64sc P] [--xvfb M] [--mame P] [--machine M] [--rompath DIR]`

`--manifest FILE` uses `<port-dir>/FILE` instead of `harness.toml` (e.g. the committed example
`ports/brickfall-coco2/harness.live.toml`).

Reads `<port-dir>/harness.toml`, verifies the pre-flight (emulator on PATH, image and symbol file
exist, required labels present, ROM found), then runs every scenario **sequentially** (emulator
concurrency is capped; there is no parallel mode), then the canary. `--keep-going` is the default.
Colour only when stdout is a terminal and `NO_COLOR` is unset.

Real output, c64 (`make -C ports/brickfall-c64/target check`):

```
gpfdiff check .. (c64, 11 scenarios, repeat 2)
scenario             steps  samples  result    secs
------------------  ------  -------  ------  ------
full_win              3972      332  PASS      23.7
game_over              700       71  PASS       9.8
launch_centre          300       61  PASS       8.0
...
wall_bounces          2900      291  PASS      18.8
canary: mutated sample #2 (step 24) ball_vx 1 (was 0); rejected: MISMATCH step 24 (sample #2) field ball_vx: expected 1 got 0
CHECK PASS: 11/11 scenarios passed, x2 runs deterministic, canary rejected, 125.4s
```

(zx48 runs the same 11 scenarios in about 20 s, coco2 in about 16 s.) A failing scenario, from a golden whose `ball_vx` and
`ball_vy` were deliberately edited on line 3 (exit 1). `-` is the golden line, `+` what the emulator
produced, the carets mark the differing field:

```
launch_left      300       61  FAIL       1.1
    launch_left: run 1/2: MISMATCH step 10 (sample #2) field ball_vx: expected 1 got -128
      #0    0 0 3 0 112 0 32256 44032 0 0 ffffffffff
      #1    5 1 3 0 108 0 30720 42496 -128 -384 ffffffffff
    - #2    10 1 3 0 108 0 30080 40576 1 2 ffffffffff
    + #2    10 1 3 0 108 0 30080 40576 -128 -384 ffffffffff
                                       ^^^^
      #3    15 1 3 0 108 0 29440 38656 -128 -384 ffffffffff
      #4    20 1 3 0 108 0 28800 36736 -128 -384 ffffffffff
    differing field: ball_vx (column 9 of 11)
    columns: step mode lives score paddle_x cleared ball_x ball_y ball_vx ball_vy bricks
CHECK FAIL: 1 of 2 scenarios failed (1 passed), canary rejected, 2.1s
```

An environment error (exit 2; nothing about the game is known). Here the ROM is not where it was looked for:

```
ERROR: MAME romset `spectrum` not found (searched: ~/nonexist); the ROM is your own and is not distributed
  likely cause: MAME cannot find the `spectrum` romset. The ROM is your own and is never distributed with this repo
  next:         put spectrum.zip in ~/.mame/roms, or set ZX_ROMPATH / pass --rompath; then run: gpfdiff doctor --platform zx48
```

#### check --json

One JSON document on stdout, nothing else (the table is not printed). Schema version **2**; fields only
get added, never renamed (version 2 = version 1 plus the items marked *new*; a v1 consumer keeps working).

```json
{"schema":2, "port":"ports/brickfall-c64", "platform":"c64", "repeat":2,
 "environment_error": null,
 "scenarios":[{"name":"launch_left","steps":300,"samples":61,"runs":2,"result":"pass","secs":8.2,
               "diff":null,"error":null,"fields":[]}],
 "canary":{"ran":true,"rejected":true,"detail":"mutated sample #2 ..."},
 "summary":{"total":1,"passed":1,"failed":0,"errors":0,"secs":8.2,"verdict":"pass","expected":0,"stale":0},
 "exit_code":0,
 "expected":[], "stale":[], "oracle":{"source":"recipe","detail":".../games/brickfall/recipe/golden"}}
```

| Field | Values |
|---|---|
| `environment_error` | `null`, or `{"kind","message"}` when nothing could be run (then `scenarios` is `[]`, exit 2) |
| `scenarios[].result` | `pass`, `expected` (*new*), `fail`, `error` |
| `scenarios[].steps` / `samples` | integers, `null` when the scenario errored before they were known |
| `scenarios[].diff` | set when `fail`: `{"kind":"mismatch"\|"nondeterministic","run","of","sample","step","field","expected","got","tolerance"}`; `field` is a column name or `<line>` for a length difference; `step` is `null` if the trace has no `step` column; `tolerance` (*new*) is `null` or the tolerance that was in play |
| `scenarios[].fields` (*new*) | one entry per field that differs in this scenario (pass fields are omitted): `{"field","verdict":"expected"\|"fail","count","sample","step","expected","got","tolerance","reason","until"}` where `count` = differing samples, `sample`/`step`/`expected`/`got` = the first one, `reason`/`until` are set for `expected` |
| `scenarios[].error` | set when `error`: `{"kind","message"}` |
| error `kind` | `emulator_missing`, `emulator_exited`, `timeout`, `ready_gate` (*new*: keys mode, the `[boot] ready` gate never held), `desync`, `missing_label`, `missing_rom`, `missing_file`, `script_error`, `config`, `other` |
| `canary` | `null` with `--no-canary`; `ran:false` if no scenario passed to mutate; `rejected:false` with `ran:true` = broken harness (exit 2) |
| `summary.verdict` | `pass`, `expected` (*new*: no failure, at least one EXPECTED scenario), `fail`, `error`, matching `exit_code` 0, 0, 1, 2 |
| `summary.expected` / `stale` (*new*) | counts of EXPECTED scenarios and of STALE expectations |
| `expected` (*new*) | flat list `{"scenario","field","reason","until","count"}` of every expected deviation that triggered |
| `stale` (*new*) | `{"axis","scenarios","reason","until","why"}` for every expectation that never triggered (a warning, never an error) |
| `oracle` (*new*) | `{"source":"recipe"\|"trace"\|"live","detail"}` (directory or port name); `null` on environment errors |

`--list` prints scenario names with step counts (with `--json`: a JSON array of names).

### capture

`gpfdiff capture <port-dir> [--manifest FILE] [--scenario a,b | all] [--out DIR] [--repeat N] [--timeout S] [emulator flags]`

Runs the port's own target (its `harness.toml`, field map and emulator) on recipe scenarios, applies the
normalisation, and writes one `NAME.trace` per scenario, with the `# columns:` header, to `DIR` (default
`<recipe>/captured/<port-name>/`). This is how a trace is recorded from an original or from another port: capture
once, commit the numbers, and ports are verified forever with `[oracle] source = "trace"` and no original binary.
Traces of commercial games stay private; the public repo never carries them.

The determinism gate is the same as in `check` (`--repeat`, default 2, fresh emulator each, identical traces): a
scenario whose runs differ is **not written** and the command exits **2** (`NON-DETERMINISTIC`): a recording that
differs from itself is a harness/environment problem, not a result about a game, exactly as a live oracle that fails its own
gate is. (`capture` has no exit 1: it compares nothing against a golden.) Works with a keys-mode (black-box) manifest
exactly like a cooperative one: `gpfdiff capture ports/brickfall-zxspectrum48/blackbox` records the Spectrum game with no
`gpf_state` and the result equals the reference model's golden.
Real output (`gpfdiff capture ports/brickfall-zxspectrum48 --out /somewhere`, the last lines):

```
captured speedup: 151 samples, x2 deterministic -> /somewhere/speedup.trace
captured wall_bounces: 291 samples, x2 deterministic -> /somewhere/wall_bounces.trace
CAPTURE OK: 11 scenarios -> /somewhere, 20.5s
```

and the file (comment lines are ignored by the parser; apart from them it equals the recipe golden, verified for
the c64, zx48 and coco2 Brickfall ports):

```
# captured by gpfdiff capture from brickfall-zxspectrum48 (zx48), scenario launch_left, 300 steps
# columns: step mode lives score paddle_x cleared ball_x ball_y ball_vx ball_vy bricks
0 0 3 0 112 0 32256 44032 0 0 ffffffffff
5 1 3 0 108 0 30720 42496 -128 -384 ffffffffff
```

### watch

`gpfdiff watch <port-dir> [--region A:B] [--keys "RIGHT@500ms,FIRE@1s+250ms"] [--frames N] [--no-gate] [--max-lines N]
[--manifest FILE] [--timeout S] [--mame P] [--machine M] [--rompath DIR] [--debug]`

The discovery tool for an original that exports nothing: **press a key, see which bytes move.** It needs a keys-mode
manifest (`[input] mode = "keys"`, see below; `recipe` and `labels` may be omitted, so three lines of `platform`, `image` and
`[input]` are enough to start). It boots the program, waits for the ready gate if `[boot]` has one (else frame 0 = the first frame),
taps the scripted keys, watches every byte of the region for `--frames` frames (default 100) and prints each change by
frame. Region default: RAM without the video buffer (zx48 `0x5B00:0xFFFF`, coco2 `0x0600:0x7FFF`); addresses are
`0x1234`, `$1234` or decimal, the range is inclusive. `--keys` entries are `NAME@TIME[+HOLD]` (`500ms`, `1s`, `0.25s`;
HOLD defaults to 100 ms, a tap): `LEFT@0ms+1s` holds LEFT for a second. NAME is a button of `[input.keys]` or a key of the
platform. `--no-gate` ignores `[boot] ready`/`ready_keys` (how you find the gate in the first place).

**De-noising.** The raw material is "byte X went from a to b in frame F", one line per byte per frame would bury the answer. So:
bytes that changed **adjacent to each other in the same frame** are one group (a 16-bit counter, a position); the same
group changing in **consecutive frames** (a quiet gap of one frame is tolerated: a 50 Hz simulation on a 60 Hz clock skips one in
six) is one **burst**: first..last frame and ms, the value before the first change and after the last, and the number of frames it
changed in. A frame in which more than 512 bytes change (the region contains a screen) is not listed byte by byte, only counted.
Lines past `--max-lines` (default 200) are summarised: narrow `--region`. Columns: `frame ms addr old -> new`; ms is the
frame converted at `fps` (nearest).

**Worked example: find the paddle byte of the ZX Brickfall (an "unknown original").** Step 1: hold LEFT for a second
and watch the game's RAM (the manifest is `ports/brickfall-zxspectrum48/blackbox/harness.toml`; at this point it only needs
`platform`, `image` and the `[input]`/`[input.keys]` tables, the state map is what we are about to find; the real output below
was produced with the finished manifest, which adds the gate and the map):

```
$ gpfdiff watch ports/brickfall-zxspectrum48/blackbox --region 0xF000:0xF0FF --keys "LEFT@0ms+1000ms" --frames 60
gpfdiff watch ports/brickfall-zxspectrum48/blackbox (zx48, region 0xF000..0xF0FF, 60 frames = 1200 ms at 50 fps; gate: 1 byte at $F046 in [1, 254])
keys: LEFT@0ms+1000ms
timeline starts at boot frame 6 (the gate saw value 172)
    frame          ms  addr           old -> new
    1..60    20..1200  0xF000         00 -> 3c  (0 -> 60)  x60 frames
    1..28     20..560  0xF006         70 -> 00  (112 -> 0)  x28 frames
    1..28     20..560  0xF009         7e -> 0e  (126 -> 14)  x28 frames
    1..60    20..1200  0xF020         00 -> 3c  (0 -> 60)  x60 frames
    1..28     20..560  0xF026         70 -> 00  (112 -> 0)  x28 frames
    ...
520 byte changes at 18 addresses in 60 frames; 18 lines
```

How to read it: `0xF000` moves every one of the 60 frames, 0 -> 60: a frame/step counter (and `0xF020`, `0xF070` are copies of
it). `0xF006` moves in frames 1..28 only, from 112 down to 0 and then stops (the paddle hit the left wall at 28 frames x 4 px =
112): a position that responds to LEFT and **clamps**. `0xF009` follows it (the ball rides the paddle before launch).
Step 2: hold RIGHT instead and the same byte must go up:

```
$ gpfdiff watch ports/brickfall-zxspectrum48/blackbox --keys "RIGHT@200ms+400ms" --frames 60
   11..30    220..600  0xF006         70 -> c0  (112 -> 192)  x20 frames
```

`0xF006`: down with LEFT, up with RIGHT, 4 per frame (400 ms = 20 frames = 80 px: 112 -> 192), 112 at the start, stops at 0
(that is `paddle_x`). The copies at `0xF026`, `0xF047`, `0xF076` change in the same frames and cannot be told apart by behaviour
alone (this game keeps a working copy and a "last drawn" copy beside the published state); any of them tracks the paddle, and which
one the program itself treats as the state is a question for a disassembly or a source release. `watch` narrows the default region (42,000
bytes) to 21 addresses; it does not read the program's mind. The key is applied at the end of frame 0 and the program sees it in frame 1: the change appears
in frame 1, not frame 0 (see "Frame clock").

Finding the ready gate the same way, from the very first frame (`--no-gate`): the first lines of the output are the program's
own initialisation; the ball is drawn (`0xF045..0xF046` `00 ff -> 7e ac`, ball column 126, row 172) at frame 5, and from frame 6 on the
step counter runs:

```
$ gpfdiff watch ports/brickfall-zxspectrum48/blackbox --no-gate --region 0xF000:0xF0FF --frames 10
...
        5         100  0xF045..0xF046  00 ff -> 7e ac
    6..10    120..200  0xF000         00 -> 05  (0 -> 5)  x5 frames
```

So `$F046` (the ball's row, 255 until the first draw) in `1..=254` is a gate that says "the game has drawn its first
frame and is idle in its main loop".

Exit 0 when the run completed; 2 for any harness/environment problem (bad manifest, bad `--keys`/`--region`, the ready gate never held, ...).

### run

One scenario, one golden, explicit paths. Kept for scripts and for debugging a single case.

```
gpfdiff run --platform c64|zx48|coco2 --prg|--sna IMAGE --labels SYMBOLS --scenario S.toml --golden G.trace
            [--repeat N] [--timeout S] [--debug] [--dump FILE]
            [--x64sc P] [--xvfb auto|always|never] [--mame P] [--machine M] [--rompath DIR]
```

Output is `PASS <scenario> (...)` or `FAIL <scenario>: <report>` (then the diff context). `--dump FILE`
writes the first run's trace, which is how a golden is compared by hand. `probe` (c64: print every step
a RAM region changes, used by `soundcheck`) and `shot` (c64: screenshot at an input point) are unchanged;
their errors now carry the same cause and next-step lines.

## Field maps

By default a port is read through the built-in map: the 11 Brickfall columns decoded from `gpf_state` (16 B) and
`gpf_bricks` (5 B), exactly as always (`[state] source = "labels"`). A port that is not Brickfall, or an original
whose state lives at raw addresses, declares its own:

```toml
[state]
source = "map"

[[field]]
name = "x";      label = "player_x"                      # an assembler symbol (resolved from the symbol file) ...
scale = 0.25                                             # ... normalised: value * scale + offset
[[field]]
name = "room";   addr = 0x9001                           # ... or a raw address; size 1 (default), 2 or 4
[[field]]
name = "score";  addr = 0x9010; size = 2; endian = "be"  # endian "le" (default) | "be"
signed = false
[[field]]
name = "timer";  addr = 0x9020; size = 2; ignore = true  # collected and printed, never compared
```

| Key | Meaning |
|---|---|
| `name` | column name; unique; this is what traces, diffs and `expectations.toml` call the field |
| `addr` or `label` | exactly one. `addr` is decimal, `0x..` or `$..`, 0..0xffff. `label` is looked up in the port's symbol file (a missing one is the usual `label ... missing` environment error, exit 2) |
| `size`, `endian`, `signed` | 1/2/4 bytes, `le`/`be`, two's complement or not |
| `format` | `"number"` (default) or `"hex"`: print the `size` bytes (1..32) in memory order as lower-case hex text, e.g. the 5-byte brick bitmap `ffffffffff`; compared as text (no scale/offset/signed/endian/tolerance) |
| `scale`, `offset` | the normalisation: `value * scale + offset`, applied to what was read, **before** it is written to a trace or diffed. Printed with at most 6 decimals, integers as integers |
| `tolerance` | absolute, in **normalised** units, default 0 (exact) |
| `ignore` | printed, never compared |

Rules: `[[field]]` entries need `source = "map"`; a map needs at least one field. Reading goes through the backend's
RAM read (`Target::peek`; the MAME Lua script answers `P addr len` while parked), so the cooperative parking
(`gpf_input_ret`, the `step` desync gate on `gpf_state`) is unchanged and the three labels are still required.

**Normalisation happens on each side with that side's own manifest.** The oracle's numbers are already in the
oracle's unit space (a golden or captured trace is stored normalised; a live oracle port normalises through its own
`[[field]]` entries). The port under test normalises through its own, e.g. a CoCo port whose x is four times a
Spectrum x declares `scale = 0.25`. Both sides are then compared in the same units.

**Comparison.** Columns are matched by name. The port declares what it reads; the oracle trace must have every one
of those columns (extra oracle columns are dropped; a missing one is an environment error, `invalid oracle trace:
... no column ...`). Without a tolerance two values are equal when their text is; with `tolerance > 0` both are
parsed and may differ by up to the tolerance (inclusive). A report shows the tolerance whenever the column has one:

```
launch_left      300       61  FAIL       1.0
    launch_left: run 1/2: MISMATCH step 0 (sample #0) field paddle_x: expected 112 got 109 (tolerance 1)
    - #0    0 3 112 0 0
    + #0    0 3 109 0 0
                ^^^
      #1    5 3 108 -128 -384
    differing field: paddle_x (column 3 of 5)
    tolerance: field paddle_x allows +-1 (normalised units); this difference is beyond it
    columns: step lives paddle_x ball_vx ball_vy
```

(`paddle_x` was read with `offset = -3` and `tolerance = 1`; a difference of 3 is beyond it.) The determinism gate
between the repeated runs is always exact, in every column, ignored ones included. If the trace has no `step`
column the report says `MISMATCH sample #N` instead of `MISMATCH step S (sample #N)`.

## Expected deviations

`expectations.toml` (next to `harness.toml`, or `expectations = "path"` in the manifest) names the differences a
port is *known* to have:

```toml
[[expected_deviation]]
axis      = "ball_vx"                       # a field (column) name
scenarios = ["launch_left"]                 # optional; default = every scenario
reason    = "this port counts velocity in 1/128 px units"   # required: a silent deviation is a bug
until     = "T0123"                         # optional task id; informational only
```

**Verdicts.** Per field, then per scenario:

| Verdict | Meaning | Exit |
|---|---|---|
| PASS | no field differs beyond its tolerance | 0 |
| EXPECTED | fields differ, and **every** differing field matches a deviation (same `axis`, scenario in `scenarios` if given). Shown in the table and in the details with its reason and `until`; counted separately in the summary and JSON | 0 |
| FAIL | some differing field has no matching deviation, or the trace length differs, or the runs are non-deterministic. **FAIL beats EXPECTED**: a scenario with one declared and one undeclared difference is FAIL, and the report shows both | 1 |
| ERROR | the harness could not answer | 2 |

A deviation that never triggered in this run is **STALE**: a warning line plus `, N STALE expectation(s)` in the
summary and the `stale` list in JSON; never fatal. It is judged only over scenarios that ran (`--only` does not make
everything stale), and one that names a field the port does not have or a scenario the recipe does not have is stale
regardless. Real output (`ball_vx` read with `scale = 2` so it differs from the golden; the first deviation is scoped to
`launch_left`, the second names a field that does match):

```
gpfdiff check .../demo2 (zx48, 2 scenarios, repeat 2)
scenario       steps  samples  result      secs
------------  ------  -------  --------  ------
launch_left      300       61  EXPECTED     1.0
    launch_left: expected deviation `ball_vx`: demo: this port counts velocity in 1/128 px units [until T0123] (32 samples differ; first MISMATCH step 5 (sample #1) field ball_vx: expected -128 got -256)
launch_right     300       61  FAIL         1.0
    launch_right: run 1/2: MISMATCH step 5 (sample #1) field ball_vx: expected 128 got 256
    ...
warning: STALE expectation: axis `paddle_x`: field never differed in any scenario (reason was: demo: a deviation the port no longer has); fix the port or delete the entry
CHECK FAIL: 1 of 2 scenarios failed (0 passed, 1 expected), canary skipped, 1 STALE expectation, 2.1s
```

With no expectations file the table is the classic one (the result column is 6 wide; it is 8 wide when an
expectations file declares anything, so `EXPECTED` aligns). When nothing fails and something is expected the last
line reads `CHECK EXPECTED: 9 passed, 2 with expected deviations of 11 scenarios, ...` (exit 0). A malformed or
(explicitly named) missing expectations file is an environment error.

## Oracle sources

`harness.toml` (or an alternate manifest) says where the expected trace comes from:

```toml
[oracle]
source = "recipe"                              # default: <recipe>/golden/NAME.trace
# source = "trace"; dir  = "path"             # captured traces: <dir>/NAME.trace (relative to the manifest)
# source = "live";  port = "ports/other-port" # run THAT port's harness.toml on the same scenario; no golden file
#                   manifest = "harness.toml" # optional: which manifest of that port
```

- **recipe**: unchanged. Scenarios and goldens both come from the recipe.
- **trace**: goldens recorded by `gpfdiff capture` (possibly from a binary you no longer need). Missing file: exit 2.
- **live**: the oracle port's own `harness.toml` is loaded (its platform, image, symbol file, `[emulator]`, `[[field]]`
  scale ...) and run on the **checked port's scenario** (scenarios always come from the checked port's recipe). The two
  targets run **sequentially, never concurrently**: per scenario the oracle runs first (`repeat` fresh emulators), exits, then the
  port. Each side applies its own normalisation and the two traces are diffed; diffs name both ports
  (`oracle: live port brickfall-zxspectrum48` / `port: brickfall-coco2`). `port` is relative to the manifest directory,
  else searched up through its parents (so `ports/x` works from any port of the repo). A live oracle that fails its own
  determinism gate is an **environment error (exit 2)**: an oracle that differs from itself cannot judge anything.
  Command-line `--mame/--x64sc/--xvfb/--timeout` apply to both sides; `--machine` and `--rompath` only to the checked
  port (the oracle uses its own platform's `$ZX_ROMPATH`/`$COCO_ROMPATH`, `[emulator]`, `~/.mame/roms`).

Real output: a 60 Hz CoCo port against a live 50 Hz Spectrum port (the committed example `ports/brickfall-coco2/harness.live.toml`;
`make -C ports/brickfall-coco2/target check-live` does the same). The harness compares per simulation step, so the frame rate never enters:

```
$ gpfdiff check ports/brickfall-coco2 --manifest harness.live.toml
gpfdiff check ports/brickfall-coco2 (coco2, 11 scenarios, repeat 2)
oracle: live port brickfall-zxspectrum48 (zx48); port: brickfall-coco2 (coco2); runs sequential
scenario             steps  samples  result    secs
------------------  ------  -------  ------  ------
full_win              3972      332  PASS       8.4
...
wall_bounces          2900      291  PASS       6.5
canary: mutated sample #2 (step 24) ball_vx 1 (was 0); rejected: MISMATCH step 24 (sample #2) field ball_vx: expected 1 got 0
CHECK PASS: 11/11 scenarios passed, x2 runs deterministic, canary rejected, 35.4s
```

## Keys mode (black-box)

For a program that was **not written to cooperate**: no `gpf_state`, no `gpf_input_ret` label, no exported anything. The
program is neither parked nor modified (no breakpoint, no register or PC write; the one exception is that on coco2 the
script writes the DECB image into RAM to start it). It runs free on the emulator's frame clock while a Lua `frame_done` hook
(`lua/gpf_keys.lua`) **presses emulated keys** through MAME's own input ports (the mechanism proven by `smoke-keys`:
`ports[...]:fields[...]:set_value`) and **reads RAM** at the frames a millisecond timeline asks for. State comes only from
`[[field]]` entries with raw `addr` (a `label` works if the manifest names a symbol file, but nothing needs one).

The committed example is the ZX Brickfall treated as an unknown original, `ports/brickfall-zxspectrum48/blackbox/harness.toml`
(note: no `labels`, no `gpf_*`; addresses written as literals):

```toml
platform = "zx48"
recipe   = "../../../games/brickfall/recipe"   # scenarios (and the golden, for `check`)
[input]
mode = "keys"
[input.keys]            # button -> emulated key
LEFT  = "Z"
RIGHT = "X"
FIRE  = "SPACE"
[boot]
image = "../target/brickfall.sna"
ready = { addr = 0xF046, in = [1, 254] }       # see "Boot and the ready gate"
timeout_ms = 2000
[state]
source = "map"
[[field]]
name = "step"
addr = 0xF000
size = 2
# ... one [[field]] per column; the five brick bytes are
[[field]]
name = "bricks"
addr = 0xF010
size = 5
format = "hex"
```

Everything else is unchanged: `gpfdiff capture ports/brickfall-zxspectrum48/blackbox` records it (real output below),
`gpfdiff check` diffs it against a golden or a captured trace, and it can be the `[oracle]` of another port (live):

```
$ gpfdiff capture ports/brickfall-zxspectrum48/blackbox --out /somewhere
captured launch_left: 61 samples, x2 deterministic -> /somewhere/launch_left.trace
...
captured wall_bounces: 291 samples, x2 deterministic -> /somewhere/wall_bounces.trace
CAPTURE OK: 11 scenarios -> /somewhere, 16.6s

$ gpfdiff check ports/brickfall-coco2 --manifest harness.live-blackbox.toml     # make -C ports/brickfall-coco2/target check-live-blackbox
gpfdiff check ports/brickfall-coco2 (coco2, 11 scenarios, repeat 2)
oracle: live port brickfall-zxspectrum48/blackbox (zx48); port: brickfall-coco2 (coco2); runs sequential
scenario             steps  samples  result    secs
------------------  ------  -------  ------  ------
full_win              3972      332  PASS       7.8
...
wall_bounces          2900      291  PASS       5.9
canary: mutated sample #2 (step 24) ball_vx 1 (was 0); rejected: MISMATCH step 24 (sample #2) field ball_vx: expected 1 got 0
CHECK PASS: 11/11 scenarios passed, x2 runs deterministic, canary rejected, 33.8s
```

The 11 captured traces equal the reference model's golden traces at every sample (modulo `#` header lines): `make -C
ports/brickfall-zxspectrum48/target check-blackbox` asserts exactly that, plus the determinism of two captures, the two negative cases below and the
`watch` finding of the paddle byte.

**Manifest rules.** `[input] mode = "keys"` (default `"breakpoint"` = the cooperative contract of the rest of this
document) needs `[state] source = "map"`; `labels`, `required_labels` and `recipe` are optional; `[boot]`, `[input.keys]` and
`[time] fps`/`input_latency_frames` are only valid in keys mode. Supported platforms: `zx48`, `coco2`. **`c64` is not
supported** (the VICE backend only has the breakpoint mode); the manifest says so:
`invalid ...: `[input] mode = "keys"` is not supported for platform c64 yet (the VICE backend only has the breakpoint mode; use zx48 or coco2)`.

**Key names.** `[input.keys]` maps a button name (`LEFT`, `RIGHT`, `FIRE` are what step scenarios use through their `buttons`
bitmask 1/2/4; scenarios may name any other button or key with `press = [...]`, see above) to a key of the machine. A name is
resolved against the platform's keyboard matrix before anything runs; an unknown one is a config error, exit 2, listing the valid
names (real output):

```
$ gpfdiff check ports/brickfall-zxspectrum48/blackbox --manifest harness.badkey.toml
ERROR: invalid ports/brickfall-zxspectrum48/blackbox/harness.badkey.toml: invalid [input.keys] LEFT = "CURSORLEFT": unknown key name `CURSORLEFT` for platform zx48; valid names: A-Z, 0-9, SPACE, ENTER, CAPSSHIFT, SYMSHIFT
```

| Platform | Valid key names | MAME input fields |
|---|---|---|
| `zx48` | `A`-`Z`, `0`-`9`, `SPACE`, `ENTER`, `CAPSSHIFT`, `SYMSHIFT` (the Spectrum has no cursor keys; they are CAPSSHIFT+5..8) | `:LINE0`..`:LINE7`; the field whose name, or first word, is the key (`z    Z    :  LN ...` is `Z`) |
| `coco2` | `A`-`Z`, `0`-`9`, `SPACE`, `ENTER`, `CLEAR`, `BREAK`, `SHIFT`, `LEFT`, `RIGHT`, `UP`, `DOWN`, `COLON` `SEMICOLON` `COMMA` `MINUS` `PERIOD` `SLASH` `AT` (or the characters `: ; , - . / @`) | `:row0`..`:row6` (the keyboard matrix) |

The script requires exactly one MAME field per key and stops with `script error: key X: 0 MAME input fields match ...` otherwise.
Joystick ports and the Kempston interface are not mapped.

**Sampling and keys.** The harness runs a scenario by planning, in Rust, which frames to sample and which keys are held from which
frame (`keys.rs`, `Plan::to_text`, unit-tested); the Lua script just plays that plan, so there is no dialogue with the harness while the
emulator runs and nothing depends on wall-clock timing. Samples are read from RAM at the sample frames; only the bytes of the
`[[field]]` entries are read.

### Frame clock

Everything is relative to the **timeline**: frame 0 is the first `frame_done` hook at which the ready gate holds (or the first hook
when there is no gate). At the hook of frame `t` the script FIRST reads the samples scheduled for `t`, THEN applies the key
state for `t`; the program's next frame (`t+1`) sees that state. That is the cooperative contract moved onto a frame clock: the state read at
input point `i` has step `i`, and `buttons_at(i)` drives the step that produces `i+1`.

**Measured on Brickfall ZX (this is why `input_latency_frames` is 0 there).** A hook-by-hook log of the unmodified game with `Z` applied
at the end of hook 6 (`step`, lives, `PREV_BY`, paddle x as the game publishes them):

```
hook  step lives PREV_BY  paddle_x   note
   3     0     0       0        0    snapshot being loaded, RAM still zero
   4     0     3     255      112    init_state ran (lives = 3), nothing drawn yet ($F046 = 255)
   5     0     3     255      112    startup still running (it takes ~3 frames after the snapshot is loaded)
   6     0     3     172      112    ball drawn, program idle at its `halt`   <- the gate `$F046 in 1..=254` first holds here
   7     1     3     172      108    Z was applied at the end of hook 6: step 1 already moved the paddle
   8     2     3     172      104
```

So a key applied at hook `t` is already honoured by the **very next frame**: the emulated keyboard has no extra latency, and the
program reads the matrix once per frame after its `halt`. Hence `input_latency_frames = 0` for this program, derived from this mechanism
and not tuned: any other value shifts the whole trace (see the table in "Time axis").

**The constant offset that a careless gate introduces, and its cause.** The same game gated on `lives == 3` (`$F003`) instead
starts the timeline at hook 4, two frames **before** the program is idle in its main loop (the game's startup takes about three frames
after the snapshot is loaded; the first step happens in frame 7). Every sample is then 2 frames
early; the real diff on `launch_left` (`$F003 eq 3` gate):

```
launch_left      300       61  FAIL       0.9
    launch_left: run 1/2: MISMATCH step 5 (sample #1) field step: expected 5 got 3
```

The cause is entirely in the gate: it observed "the game's data is initialised", not "the game is running". A gate has to be a state
that is observably true at the moment the program is ready to take its first input, here "the first frame has been drawn"
(`PREV_BY` = the ball's last-drawn row, 255 before the first draw), which `watch --no-gate` shows (see "watch"). With that gate the
black-box capture is identical to the golden at every sample of all 11 scenarios (zero offset).

Two cautions. (1) The harness cannot know the right gate; **choose it with `watch`** and re-check it with a scenario that has a known answer.
(2) A real original's first frame has no fixed relation to a port's first frame, so a cross-port diff of an original has a built-in
uncertainty of about a frame; declare a `tolerance` on time-sensitive fields, or gate both sides on the same observable event.

## Boot and the ready gate

```toml
[boot]
image = "../target/brickfall.sna"       # zx48: .sna snapshot (-snapshot); coco2: DECB .bin (written into RAM by the script)
ready = { addr = 0xF046, in = [1, 254] }   # eq = N | ne = N | in = [lo, hi]; optional size = 1|2|4, endian = "le"|"be"
ready_keys = ["SPACE@50ms"]             # optional: tap keys while the gate has not held yet (dismiss a title screen)
timeout_ms = 2000                       # emulated time to wait for the gate (default 20000)
```

The gate is **observed state, never a frame count**: the timeline starts at the first frame where the condition on `size` bytes at `addr`
holds. Without `ready` it starts at the first frame (zx48) or at the frame after the image is written (coco2).
`image` may also be given at the top level (not in both with different values). `ready_keys` entries are `NAME@TIME[+HOLD]`
(same as `watch --keys`; TIME counts from the start of the boot clock; HOLD defaults to 100 ms); `NAME` is a button of
`[input.keys]` or a platform key; they are released when the gate holds. On timeout the run stops with an **environment error (exit 2)**
that names the gate and the last value seen (real output of a deliberately wrong gate, `blackbox/harness.badgate.toml`):

```
$ gpfdiff check ports/brickfall-zxspectrum48/blackbox --manifest harness.badgate.toml --only launch_left --no-canary
gpfdiff check ports/brickfall-zxspectrum48/blackbox (zx48, 1 scenarios, repeat 2)
scenario      steps  samples  result    secs
-----------  ------  -------  ------  ------
launch_left       -        -  ERROR      0.5
    launch_left: run 1: timed out waiting for the ready gate: [boot] ready (1 byte at $F046 == 7) never held within 500 ms (25 frames at 50 fps); last observed value 172 (0xAC)
      likely cause: the `[boot] ready` condition never became true: wrong address or condition, the program never started (coco2: the image load did not take), a title screen that needs `ready_keys`, or a boot slower than `timeout_ms`
      next:         see what the program writes while it boots: gpfdiff watch <port> --no-gate --region <a:b> --frames 300; then fix [boot] ready, add ready_keys, or raise timeout_ms
      more:         re-run with --debug to see the monitor protocol and emulator output
CHECK ERROR (exit 2, harness/environment, not a game failure): 0 passed, 0 failed, 1 errored of 1, canary skipped, 0.5s
```

(JSON error kind `ready_gate`.) coco2: the Lua script sets `CC |= $50`, writes the segments and sets `PC`, reads `PC` back, as in the
cooperative backend. Because nothing is parked there is no breakpoint to prove the program started, so the gate is the proof: if it times
out and the CPU is **outside** the loaded image (a PC write that did not start the program: MAME can resume half a BASIC
instruction), the whole boot is retried in a fresh MAME, at most 3 times; the message then says `PC=$xxxx (outside the loaded image ...)`.
A coco2 manifest should therefore have a `ready` gate. Checked on the CoCo Brickfall port: `gpfdiff watch` on a keys-mode manifest with
`ready = { addr = 0x1003, eq = 3 }` boots the DECB image, holds LEFT and reports the paddle byte moving 112 -> 12.

## Time axis

Scenarios and `watch` are in **milliseconds**; each machine converts to its own frames. Never share a raw frame axis between a 50 Hz and a 60 Hz machine.

* `[time] fps`: the nominal frame rate that converts ms to frames. Default per machine: **zx48 50, coco2 60, c64 50**. It is a
  conversion constant, not a measurement of the emulator (MAME's real rate differs by a fraction of a percent; frames are counted, not timed).
* `[time] step_ms` (default 20): the length of one scenario step. `step = N` in a scenario is `at = N * step_ms` ms.
* **Rounding rule (one rule everywhere):** `frame = (ms * fps + 500) / 1000` in integer arithmetic, i.e. the **nearest frame, halves
  round up**. It applies to key changes, `duration_ms` releases, `ready_keys`, `--keys`, sample instants and the end of the scenario.
  At 50 Hz and 20 ms steps every step lands exactly on frame N; at 60 Hz a step is 1.2 frames, so steps 0..5 land on frames
  `0 1 2 4 5 6`. Samples are taken **at the frame nearest the scheduled time**. Two samples that round to the same frame
  (`sample_every_ms` shorter than a frame) are an error (`invalid scenario ...: sample_every is shorter than a frame`), never a silently shorter trace.
* **The step-based scenarios run unchanged:** the 11 Brickfall scenarios are step-authored; at 50 Hz sample `k` is at frame `k * sample_every` and
  the black-box capture equals the golden.
* `[time] input_latency_frames` (default 0): the fixed number of extra frames the program takes to see a key. Every key change is applied
  that many frames earlier (a change that would have to precede the timeline start is an error, not a silent clamp). It exists for programs
  that poll input in a later frame than the hook that applied it (for instance one that latches the keyboard from an interrupt that
  ran before the hook) and is **derived from a mechanism, not tuned to pass**: apply one key at the end of frame `t`, watch the frame in which the
  bytes move (`watch --keys`, or the hook log above), and set the knob to that frame minus `t + 1`. For Brickfall ZX it is 0 (above). Evidence that
  the knob has teeth and aligns when it is right (fake-MAME tests `keys_mode_passes_with_the_right_latency_knob_and_fails_without_it`): a program
  with one extra frame of latency fails with `MISMATCH sample #3 field x: expected 99 got 100` at knob 0 and passes at knob 1; at knob 1 on the real
  game the scenario `launch_left` (input at frame 0) is rejected with `an input at 0 ms (frame 0) is earlier than input_latency_frames = 1`.

Cooperative targets ignore `fps`; they run the step view (ms converted to steps by the same rounding rule at `step_ms`).

## CoCo 2 (`coco2`)

Same shared MAME transport and Lua driver as zx48, with three differences (details in
`ports/brickfall-coco2/NOTES.md`):

1. **Loading.** `coco2b` has no headless loader, so `coco.rs` parses the DECB `.bin` (`parse_decb`: `00 LLLL AAAA data...`
   blocks, `FF 0000 EEEE` entry) and hands the Lua script a *load list* (`GPF_LOAD`, lines `S <addr> <hex>` and `X <entry>`).
   The script waits 150 frames (BASIC's cold start is still sweeping RAM before that), sets `CC |= $50` (IRQ/FIRQ masked),
   writes the segments, sets `PC`, reads `PC` back, and if the program has not reached `gpf_input_ret` within 30 frames
   (MAME suspends the 6809 mid-instruction at frame boundaries, so a PC write can resume half of a BASIC instruction)
   it `soft_reset`s and retries, at most 5 times. Segments at `$8000+` are rejected up front: the BASIC ROM is mapped
   there at load time (`factory/platforms/coco2.toml [load]`). The entry point and `gpf_input_ret` must lie inside a loaded
   segment (catches a map from a different build).
2. **Input register.** `A` (`GPF_REG`, MAME's 6809 state name `A`); verified by reading it back in the ACK, like zx48.
3. **Command line.** `mame coco2b -rompath ... -ext ""` (no cartridge/disk extension). `-ext ""` makes BASIC come up on its own.

The port must publish `gpf_state` little-endian although the 6809 is big-endian: see the brickfall-coco2 `publish`.
Pacing is the port's business: NTSC fields are 60 Hz, a sim step is 50 Hz, so the port runs an accumulator (add 5 per
field, step and subtract 6 when >= 6); the harness compares per STEP and never sees the difference.

## Exit codes

| Code | Meaning | Commands |
|---|---|---|
| 0 | every scenario PASSED or is EXPECTED (all differences declared in `expectations.toml`), canary rejected (or `--no-canary`); STALE expectations only warn; `capture`/`watch`: completed | check, run, capture, watch, doctor |
| 1 | the port FAILED: a trace differs from the oracle beyond tolerance and undeclared, or the length differs, or two runs differ from each other (`NON-DETERMINISTIC`; `check`/`run` only) | check, run |
| 2 | the harness or environment could not answer: tool or ROM missing, timeout, desync, bad manifest/scenario/golden/expectations, oracle trace missing or lacking a column, live oracle port missing or non-deterministic, canary not rejected, keys mode: unknown key name, ready gate never held, bad `--keys`/`--region`; **`capture`: a scenario whose runs differ (nothing is written for it)**; doctor: a required item missing | check, run, capture, watch, doctor |

With several scenarios, any code-2 condition wins over code 1 (the answer is incomplete). `probe` and
`shot` exit 1 on any error, as before. `run` used to exit 1 for environment errors too; it now exits 2.

## Adding a backend

This is for the cooperative (parked) contract. Keys mode is not a `Target`: it has no parking point; a new emulator would need its own
runner like `keysrun.rs` that plays a `keys::Plan` (frame clock, key state, RAM reads) and returns samples.

A backend is one file implementing `target::Target`. The core never knows which emulator it talks to.

```rust
pub trait Target {
    fn boot(&mut self) -> Result<(), String>;                 // start emulator, load image, run to the FIRST input point
    fn read_state(&mut self) -> Result<RawState, String>;     // gpf_state (16 B) + gpf_bricks (5 B) while parked
    fn provide_input(&mut self, buttons: u8) -> Result<(), String>; // inject, VERIFY, resume, run to the NEXT input point
    fn shutdown(&mut self);                                   // stop the emulator; safe to call twice
    fn peek(&mut self, addr: u16, len: usize) -> Result<Vec<u8>, String> { .. }       // optional (probe; REQUIRED for [[field]] maps)
    fn label(&self, name: &str) -> Option<u16> { None }                               // optional (`[[field]] label = ...`)
    fn screenshot(&mut self) -> Result<png::Image, String> { .. }                     // optional (shot)
}
```

"Parked" means: the program is stopped at `gpf_input_ret`, about to consume this step's buttons, and
`gpf_state` holds the state after the previous step and is not being written.

`mame.rs` as the worked example:

1. `MameTarget::new(cfg)` reads the symbol file (`parse_labels`) and requires `gpf_state`, `gpf_bricks`,
   `gpf_input_ret`. A missing one must produce the text ``label `NAME` missing from FILE``.
2. `boot()` writes the embedded Lua script (`include_str!("../lua/gpf_mame.lua")`) to a temp file and spawns
   `mame spectrum -snapshot IMG -autoboot_script SCRIPT -video none -sound none -nothrottle -debug -debugger none
   -noreadconfig`, passing the three addresses in `GPF_STATE`/`GPF_BRICKS`/`GPF_RET`. Spawn failure must say
   ``cannot start `EXE`: ...``. stdout and stderr are drained by reader threads into one `mpsc` channel
   (so waits can time out); non-protocol lines are kept in a 12-line ring and appended to error messages.
3. The IPC pattern, the same idea in both backends: the emulator side stops the CPU at `gpf_input_ret` and
   **blocks waiting for the harness**, so emulation is frozen while the harness thinks and nothing depends on
   timing. MAME: the Lua script prints `GPF S <42 hex digits>` and blocks on `io.stdin:read("l")`. VICE
   (`c64.rs`): an exec checkpoint on the `RTS` stops the CPU and the binary monitor on a TCP port is the channel.
4. `provide_input(n)`: send `B n`; the script writes `A = n`, **reads A and PC back**, prints
   `GPF ACK <A> <PC>` and resumes. The Rust side runs `check_ack`: A must equal `n` and PC must still be
   `gpf_input_ret`. This is the "did the write take" gate: never trust a register write you did not read
   back. Then parse the next `GPF S` line. (VICE does the same with registers-set then registers-get.)
5. Do not check step counters in the backend. The core compares the program's own `step` field to the input
   point index and raises ``harness desync: ...`` on any drift (a missed or doubled stop).
6. `shutdown()`: send `Q`, wait up to 3 s, then kill; also kill helper processes (VICE: the whole process
   group, because of `xvfb-run`). Call it from `Drop` too.
7. Register it: add the platform to `runner::make_target`, to the platform lists in `manifest.rs` and
   `doctor.rs` (`tools_for`, `preflight_files`, `remediation`), and the emulator name in `errors::hint`.
8. Test the transport without the real emulator: see `mame.rs` tests, where a bash script speaks the protocol
   (`fake()`), including a variant whose third ACK lies. `check.rs` tests run the whole `check` pipeline
   against such a fake.

A second platform on the same emulator is cheaper than a new backend: `coco2` is `MameKind::Coco2` in `mame.rs`
(different loader, symbol parser and machine name, same transport and Lua driver), with its pure logic in `coco.rs`.
Reuse that route whenever the new target runs under MAME with a debugger-addressable register for the input byte.

Wording the error classifier relies on (`errors::classify`), so reuse these phrases:

| Phrase in the error string | Classified as |
|---|---|
| `harness desync` | desync (exit 2) |
| ``label `X` missing from FILE`` | missing_label |
| `romset`, `required files are missing` | missing_rom |
| ``invalid ...`` (also: `invalid oracle trace`, `invalid expectations`) | config |
| `timed out` | timeout |
| ``cannot start `EXE` `` | emulator_missing |
| `exited`, `closed the monitor`, `could not connect` | emulator_exited |
| `script error` | script_error |
| `no such file` | missing_file |

A comparison failure is never an `Err(String)`: it is a `FailInfo` from `runner::compare_runs` (exit 1).

## Troubleshooting

Built from the dead ends recorded in `ports/brickfall-c64/NOTES.md` and `ports/brickfall-zxspectrum48/NOTES.md`.

| Symptom | Cause | Fix |
|---|---|---|
| `cannot start 'x64sc'` / `'mame'`: not found on PATH | emulator not installed, or not on PATH | `gpfdiff doctor`, run the printed install line, or pass `--x64sc`/`--mame` or set `[emulator]` |
| `MAME romset 'spectrum' not found` | the Spectrum ROM is yours to supply; it is not in the repo | put `spectrum.zip` in `~/.mame/roms`, or set `ZX_ROMPATH`, or `--rompath`. `mame -verifyroms spectrum` still reports `testromv037.bin NOT FOUND` for a good zip: that file is an optional diagnostic ROM, ignore it |
| a VICE window appears on your desktop | `xvfb-run` not installed (`--xvfb auto` found none) | install it (`gpfdiff doctor` prints how), or accept the window |
| `stopped at PC $fd75 ... expected gpf_input_ret`, hundreds of spurious stops | a command was sent to VICE while the CPU was running (any monitor command stops it at an arbitrary PC); in particular `exit` right after autostart | backend bug. Correct sequence: ping, regs-avail, set checkpoint, autostart, wait for the resume event, wait for the stop event. Checkpoint BEFORE autostart so step 0 is not missed |
| `timed out waiting for the emulator` / `MAME` | program never reached `gpf_input_ret`; image and symbol file from different builds; machine overloaded | rebuild both together (`make -C <port>/target`), then `--timeout 120 --debug` |
| `label 'gpf_input_ret' missing from ...` | stale `.vs`/`.sym`, or the label was removed. On c64 these must be plain labels or `=` constants so `--vicelabels` lists them | rebuild; `grep gpf_ <symbol file>` |
| `harness desync: at input point 3 the target reports step 4` | a breakpoint hit was missed or doubled; or the program runs more than one step per input point | exit 2 by design. Never trust a diff after this. Check that `gpf_input_ret` labels the `ret` itself, run one scenario with `--debug` |
| `script error: PC write did not take` / `image never reached gpf_input_ret after 5 loads` (coco2) | MAME resumed a half-done BASIC instruction on every try, or the image does not start at the DECB entry | check `lds`/`start` is the DECB exec address and that nothing at `start` needs BASIC; the Lua script already retries 5 times |
| `invalid ...bin: entry $xxxx or gpf_input_ret $xxxx is not inside a loaded segment` (coco2) | `.map` and `.bin` from different builds | rebuild both: `make -C <port>/target` |
| `DECB: segment ... reaches $8000+` (coco2) | image would load over the BASIC ROM; the stock loader drops those writes | keep code/data below `$8000` (or stage and relocate; see `factory/platforms/coco2.toml`) |
| `register write did not take` | `gpf_input_ret` is not on the instruction whose result is `A` (wrong label) | point the label at the `RTS`/`ret` of `read_input` |
| `NON-DETERMINISTIC: run 2 differs from run 1` | the port's state depends on timing, uninitialised RAM, or boot timing | fix the port. The sim must not depend on raster/frame timing. Exit 1, not a harness error |
| a `make check` that passes but a scenario hides a bug | sampling hides a one-step difference: the miss threshold `cmp #193`->`#194` is invisible at `sample_every = 5`, caught at 1 | add a `sample_every = 1` scenario (that is why `miss_dense` exists). Scenarios are recipe: a top-tier decision |
| `invalid oracle trace: the oracle trace has no column 'x'` | the port's field map reads a column the golden/captured trace does not have | add the column to the oracle (recapture) or drop the `[[field]]`. Only the port's columns are compared; extra oracle columns are fine |
| every sample of a mapped field is off by a constant factor | the port is in other units than the oracle | `scale`/`offset` on the PORT's `[[field]]` (value * scale + offset), e.g. `scale = 0.25` for CoCo x vs Spectrum x |
| a diff you expected to be absorbed still FAILs, `(tolerance N)` in the report | the difference is beyond the tolerance (inclusive, absolute, normalised units) | check the units first (scale), then widen the tolerance, or declare the field in `expectations.toml` |
| `warning: STALE expectation` | an `[[expected_deviation]]` that never triggered: the port now matches, or the axis/scenario name is wrong | delete the entry or fix the name; never fatal |
| `live oracle ... failed its own determinism gate` (exit 2) | the oracle port is non-deterministic, so it cannot judge | fix or `capture` a trace from a deterministic build; `[oracle] source = "trace"` |
| `live oracle: invalid [oracle] port: ... not found` | `port` is neither under the manifest dir nor under any of its parents | fix the path in `[oracle]` |
| `invalid expectations ...` (exit 2) | malformed `expectations.toml` (a deviation needs `axis` and `reason`) or an explicit `expectations = "..."` path that does not exist | fix the file |
| `timed out waiting for the ready gate: [boot] ready (...) never held ...; last observed value N` (exit 2) | keys mode: wrong gate address/condition, the program never started (coco2: image load did not take), a title screen with no `ready_keys`, or `timeout_ms` too short | `gpfdiff watch <port> --no-gate --region a:b --frames 300` shows what the program writes while booting; pick a byte that changes exactly when it is ready |
| every sample of a black-box capture is off by a constant number of steps | the ready gate fires earlier/later than the moment the program starts taking input (e.g. gating on "data initialised" instead of "first frame drawn"): see "Frame clock" | choose a gate that is observably true when the first input is taken; `watch --no-gate` |
| black-box state moves one frame before/after the golden after a key change | the program sees keys a different number of frames after they were applied | measure it (`watch --keys`), then `[time] input_latency_frames` (README "Time axis"); never tune it until a trace passes |
| `invalid ... unknown key name `X` for platform P; valid names: ...` (exit 2) | a key in `[input.keys]`, `ready_keys`, `--keys` or a scenario `press` does not exist on that machine | use one of the listed names (the Spectrum has no cursor keys) |
| `button FIRE has no key: add `FIRE = "<key>"` to [input.keys]` | a scenario presses a button the manifest does not map | add it to `[input.keys]` |
| `key X: 0 MAME input fields match ...` (script error) | the key name resolved to text that no MAME input field of this machine has (MAME renamed a field) | `mame <machine> -listxml`, or print `ioport.ports[...].fields` in a script; report it |
| `invalid scenario: the samples at A ms and B ms both land on frame F` | `sample_every_ms` is shorter than a frame at this machine's fps | sample at least one frame apart |
| `watch` lists hundreds of lines / `bulk: more than 512 bytes changed per frame` | the region contains a screen, a sound buffer or a timer | narrow `--region`; the default excludes the ZX/CoCo video RAM |
| `canary: ... accepted it` / `CANARY NOT REJECTED` | the comparison cannot fail | harness bug (exit 2). Run `cargo test --offline` in this directory |
| `unexpected display reply` (`shot`) | VICE sends the display buffer 4 bytes short (3.10) and warp mode skips frames | the crop code only needs the rows it uses; use real time (`shot` does) |
| real joystick/keyboard input is not covered by `check` | `joyport set` does nothing in headless x64sc; xdotool keys never reach MAME under Xvfb; VICE keyboard-buffer input cannot drive a game that reads the CIA matrix directly | not automatable on c64: test `read_input` by hand. zx48: `make smoke-keys` presses keys in MAME's emulated matrix |
| MAME writes a `cfg/` directory into the source tree | MAME saves config on exit into the cwd | already avoided: the backend passes `-cfg_directory` under the temp dir and `-noreadconfig` |
| `sjasmplus --version` prints `Unrecognized option` | that sjasmplus build has no such flag; the binary works | ignore; `doctor` does not use it |
| `yay -S sjasmplus` fails at the sudo step in a non-interactive shell | yay cannot prompt | extract `usr/bin/sjasmplus` from `~/.cache/yay/sjasmplus/*.pkg.tar.zst` into `~/.local/bin/` |
| machine freezes / OOM during a batch of emulator runs | too many emulators at once (a 12-way MAME batch did this) | `check` is sequential by design; keep any outer batching to 2-3 at a time |

## Tests

`cargo test --offline --manifest-path factory/tools/gpfdiff/Cargo.toml` (154 tests, about 4 s, no real
emulator needed). It covers manifest parsing, the lwasm map and DECB parsers, table and JSON rendering, doctor
remediation selection (including the CoCo ROM), error classification and exit-code mapping, the canary, and
end-to-end `check` runs against a fake MAME (zx48 and coco2: the fake refuses to start unless it is handed the
`coco2b` machine, `-ext ""` and a correct load list), including a
deliberately broken golden (exit 1, exact diff line) and environment errors (missing emulator, missing ROM,
missing label, timeout, no manifest: exit 2).

The oracle-mode tests (`check.rs`) run the whole pipeline against a fake MAME that also answers RAM reads (`P addr len`): a
field scaled x4 on one side PASSes with `scale = 0.25` and FAILs without it; tolerance 1 absorbs +-1 jitter and tolerance 0
rejects it; a declared deviation is EXPECTED (exit 0), the same field undeclared is FAIL (exit 1), FAIL beats EXPECTED, an
unused deviation is STALE; `capture` output equals the golden and feeds a `trace` oracle; a `live` oracle normalises both
sides, names both ports, and is an environment error when it is non-deterministic.

Keys-mode tests: pure logic (ms to frame conversion and rounding, gate evaluation and parsing, scenario ms parsing, key-name resolution
and its error text, key scripts, plan text, the watch de-noising) and an end-to-end run against a fake MAME that plays the plan file the way
`gpf_keys.lua` does: it refuses to start with `-debug` or without `-snapshot`, simulates a free-running program whose input latency can be set,
and prints the same `GPF` lines. They prove: PASS with the right `input_latency_frames` and a one-frame miss without it, `capture`
equals the golden, a gate timeout is exit 2 with the gate and last value (JSON kind `ready_gate`), an unknown key lists the valid names,
a keys-mode port works as a live oracle for a cooperative port, `watch` reports the moved address by frame. The Lua script itself and the real keyboard
matrices are covered by the real-MAME checks: `make -C ports/brickfall-zxspectrum48/target check-blackbox`.
