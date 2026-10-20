# gpfdiff oracle mode — design

Status: phase 2 implemented (part A: field maps, tolerance, expectations, capture, live oracle; part B: keys mode,
boot gate, time axis, `watch`, black-box capture). Phase 1 (CoCo backend) is the cooperative mode this extends. Phase 3 (docs +
factory integration) is not started. README.md documents the implemented behaviour; the deviations from the text below are listed at the end.

## Problem

Today a target *cooperates*: the program exports `gpf_state` and a `gpf_input_ret` label, the
harness parks it at the input point and diffs against a reference-model trace. That only works
for programs we wrote. When porting an existing game, the **original binary is the oracle**: it
has no labels, no state block, no parking point. We must read its game state out of raw RAM,
drive it with injected keys on a frame clock, and diff the *port* against what the original did.

## Principles (each is a lesson already paid for in this repo)

1. **Gate on observed state, never frame counts.** The scenario timeline starts when a RAM
   condition says the game really started (title screens and loaders take variable time).
2. **Author scenarios in milliseconds.** Source and target run at different frame rates
   (Spectrum 50 Hz, CoCo 60 Hz). Convert per side; never share a raw frame axis.
3. **Normalise units, then compare.** Fields are scaled/offset into a common unit space before
   diffing (e.g. CoCo x / 4 == Spectrum x).
4. **Tolerance is declared per field, deviations are named.** A mismatch is FAIL unless it is
   within tolerance or matches a declared `expected_deviation`, which reports EXPECTED (visible,
   never silent) and carries a reason. Stale expectations are themselves a bug.
5. **Determinism before diffs.** Same repeat gate as cooperative mode.
6. **A recorded trace is as good as a live oracle.** `capture` once from the original, commit
   the trace (numeric state facts), and the port is verified forever without the original binary.
   Keep traces of commercial games private; the public repo never carries them.

## What changes

### 1. State maps (`[[field]]`) replace the fixed 11 columns

`harness.toml` may declare fields instead of relying on `gpf_state`:

```toml
[state]
source = "map"          # "labels" (default, cooperative gpf_state) | "map"

[[field]]
name = "x";      addr = 0x5C00; size = 1                       # or label = "player_x"
[[field]]
name = "room";   addr = 0x5C10; size = 1; tolerance = 0         # exact
[[field]]
name = "score";  addr = 0x5C20; size = 2; endian = "le"; signed = false
[[field]]
name = "x";      scale = 0.25                                   # port side: CoCo px -> ZX px
```

A field has: `name`, `addr` or `label`, `size` (1/2/4), `endian`, `signed`, `scale`, `offset`
(applied after read: `value*scale+offset`), `tolerance` (absolute, in normalised units, default 0),
`ignore` (collected but not compared). The trace header line carries the column names, so goldens
are self-describing; the default Brickfall trace is just a map with 11 columns.

### 2. Frame-synchronous input (`[input] mode = "keys"`)

No breakpoint. A Lua `frame_done` hook counts frames from the **ready gate**, and at each
frame applies the scenario's button state by driving the emulator's own input ports
(`ports[...]:fields[...]:set_value`, proven by `smoke-keys` for the Spectrum). `[input.keys]`
maps buttons to emulator keys (`LEFT = "Z"`, ...). Sampling reads RAM at frames derived from the
scenario's millisecond timeline for that machine's fps. Cooperative mode (`mode = "breakpoint"`)
is unchanged and stays the default.

### 3. Boot and ready gate (`[boot]`)

```toml
[boot]
image = "original/game.sna"          # snapshot (zx), DECB bin (coco), prg (c64)
ready = { addr = 0x5C00, ne = 0 }    # observed-state gate; eq / ne / in = [lo, hi]
ready_keys = ["SPACE@50ms"]          # optional: dismiss title screens until ready
timeout_ms = 20000
```

### 4. Scenarios in real time

Scenario files keep `[[input]] step = N` for cooperative mode; oracle mode adds `at_ms = N` and
`duration_ms` (buttons hold until the next entry), `sample_every_ms`, `length_ms`. One scenario
file can drive a cooperative target and an oracle target; steps-vs-ms is resolved per backend.

### 5. Commands

- `gpfdiff capture <port-dir> --scenario S --out golden/S.trace` — run a target (cooperative or
  oracle) and write its normalised trace. The only way goldens come from an original.
- `gpfdiff check <port-dir>` — unchanged UX; the manifest's `[oracle]` block says where goldens
  come from: `recipe` (model, today) | `trace = "path"` (captured) | `live = "ports/other"`
  (run the other port's harness.toml on the same scenario and compare the two, no file).
- `gpfdiff watch <port-dir> [--region a:b]` — run the original with manual or scripted keys and
  print every RAM change by frame. This is the address-discovery tool: press a key, see which
  bytes move. Builds on the existing `probe`.

### 6. Expected deviations (`expectations.toml` next to harness.toml)

```toml
[[expected_deviation]]
axis = "color"          # a field name or capability
reason = "CoCo PMODE4 is 1bpp; Spectrum has attribute colour"
[[expected_deviation]]
axis = "room_name"; scenarios = ["walk_left"]; until = "T0123"   # temporary, tied to a task
```

Verdicts: PASS, EXPECTED (matches a deviation), FAIL. `check --json` reports all three, and a
deviation that no longer triggers is warned as stale.

## Acceptance (public, no copyrighted game)

Brickfall is the test vehicle because its three ports already exist:

1. **Black-box fidelity.** Treat the ZX Brickfall as an *unknown original*: no `gpf_state` label,
   no `gpf_input_ret`, only a state map of raw addresses and a key map. `capture` its trace in
   oracle mode and assert it equals the reference model's golden at every sample (proves the
   black-box machinery reads and times the original faithfully).
2. **Live cross-port diff.** `check ports/brickfall-coco2` with `[oracle] live = "ports/brickfall-zxspectrum48"`
   PASSes: a 60 Hz CoCo port matches a 50 Hz Spectrum original, using the ms timeline.
3. **Normalisation.** A synthetic port variant with x scaled by 4 (unit test or a build flag)
   PASSes with `scale = 0.25` and FAILs without it; tolerance 1 absorbs a +-1 jitter and tolerance 0
   rejects it.
4. **Expected deviations.** A deliberately introduced known difference is EXPECTED, reported, and
   a stale entry is warned.
5. **Discovery.** `watch` on ZX Brickfall finds the paddle byte when LEFT/RIGHT are pressed
   (shown in the guide as the way to find an original's state addresses).
6. Existing cooperative checks (C64, ZX, CoCo) are byte-for-byte unaffected.

## Out of scope for phase 2

Pixel-level image diffing, audio comparison, and automatic address discovery. `watch` plus a
disassembly (skool/asm listings from prior art) is the intended workflow; screenshots and sound
stay human-or-vision-model checks.

## Phase 3 (docs + factory integration)

`gpf init` for existing games seeds harness tasks that name this mode; GETTING-STARTED gains a
"port an existing game" chapter built from the Brickfall-as-original exercise; a template
`harness.toml` + `expectations.toml` + `state_map` scaffold command; CLAUDE.md session protocol
mentions `watch`, `capture` and oracle mode.

## Deviations of the implementation from this design (part B)

- **Keys mode is not a `Target`.** There is no parking point, so the planned "same runner, different backend" did not fit. The Rust side
  computes a *plan* (frames to sample, key state per frame, regions to read; `keys.rs`) and writes it to a file; `lua/gpf_keys.lua` plays it
  free-running and prints samples. No stdin dialogue, no `-debug`, no breakpoint. `runner::run_traces` picks the path, so `check`, `capture` and live oracles
  need no change.
- **Frame semantics fixed:** at the hook of timeline frame `t` samples for `t` are read first, then the key state for `t` is applied (seen by frame
  `t+1`). Measured on Brickfall ZX: zero extra input latency, so `[time] input_latency_frames` defaults to 0 and is 0 there; the knob exists (it lives in
  `[time]`) and is exercised by fake-MAME tests.
- **Fields:** `format = "hex"` (raw bytes as hex text, any size 1..32) was added: the Brickfall `bricks` column is a 5-byte bitmap and the numeric sizes (1/2/4) could not
  reproduce the golden.
- **Scenarios:** besides `at_ms`, `duration_ms`, `sample_every_ms`, `length_ms`, an entry may use `press = ["LEFT", "Q"]` (names; LEFT/RIGHT/FIRE fold into the `buttons`
  bitmask, other names need keys mode). Rounding rule: nearest frame, halves up, `(ms*fps+500)/1000`.
- **Key names** are static per-platform tables validated when the manifest loads (unknown key = exit 2 listing the valid names); matching a MAME field is by whole
  name or first word.
- **`[boot]`:** `image` may sit at the top level or in `[boot]`; `ready` accepts `size`/`endian` beyond `addr` and `eq|ne|in`; `ready_keys` entries are
  `NAME@TIME[+HOLD]` taps (hold defaults to 100 ms; the design did not say). A gate timeout is its own error kind (`ready_gate`, exit 2). coco2 retries the boot (max 3) when the gate times
  out with the CPU outside the loaded image, replacing the breakpoint-based retry of the cooperative backend.
- **`watch`** needs a keys-mode manifest (`recipe`/`labels` may be omitted), takes `--no-gate` and `--max-lines`, default regions exclude video RAM, de-noises
  by grouping adjacent bytes and merging bursts (a quiet gap of one frame is tolerated), and counts frames with more than 512 changed bytes instead of listing them.
- **`capture`** of a non-deterministic scenario is exit **2** (was 1), consistent with a live oracle failing its own gate.
- **c64** keys mode is reported as unsupported at manifest load. **coco2** keys mode is implemented and was exercised with `watch` on the CoCo Brickfall port; the acceptance
  traces use the Spectrum as the black-box original.
- A manifest kept in a sub-directory of a port (`ports/x/blackbox`) is named `x/blackbox` in reports.
