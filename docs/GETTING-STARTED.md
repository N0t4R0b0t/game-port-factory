# Getting started

About 30 minutes, most of it waiting for emulators. By the end you will have built the
tools, watched two ports of one original game pass the same tests on a Commodore 64 and a
ZX Spectrum, broken the game on purpose to see the harness catch it, and know how to start
your own port.

The examples are 8-bit computers because that is where the project started; the workflow is
the same for any source and target, including consoles and DOS PCs. What changes per system
is its platform profile and the emulator backend the harness uses to drive it.

If you only want the idea first, read the [README](../README.md) (five minutes) and come back.

## The one idea you need

Porting a game is hard to automate because "does it still play right?" normally needs a
human watching a screen. This project removes the human from that question:

```
 rules (recipe)  ──►  reference model (Rust)  ──►  golden traces
                                                        │ compared step by step
 your port (6502 / Z80 / 6809 ...)  ──►  emulator  ──►  gpfdiff  ──►  PASS / FAIL
```

Every port exposes a small block of RAM (`gpf_state`). The harness runs the port in an
emulator, injects scripted input, reads that block after every simulation step, and diffs it
against the reference. A cheap model, a script or a CI job can run that check and trust the
answer. Everything else in the repo (the stage model, the task graph, the handoff notes)
exists so that work on a port can stop and resume weeks later without losing anything.

## 1. Prerequisites

You need **Rust** (`rustup`) and, for the demo, an assembler and an emulator per platform.
The harness can tell you what is missing and how to fix it:

```bash
git clone https://github.com/N0t4R0b0t/game-port-factory.git
cd game-port-factory
cargo build --release --manifest-path gpf/Cargo.toml
cargo build --release --manifest-path factory/tools/gpfdiff/Cargo.toml
factory/tools/gpfdiff/target/release/gpfdiff doctor --platform all
```

`doctor` prints OK / MISSING / OPTIONAL for each tool, with the install command for Arch,
Debian/Ubuntu and macOS. It never installs anything. What you need:

| For | Tools |
|---|---|
| Commodore 64 demo | `acme`, VICE (`x64sc`); `xvfb-run` optional (keeps emulator windows off your desktop) |
| ZX Spectrum demo | `sjasmplus`, MAME, and **your own** `spectrum.zip` ROM set |
| Screenshots | ImageMagick `magick` (optional) |

**The Spectrum ROM is not included and never will be.** Put your own `spectrum.zip` (the MAME
`spectrum` romset, one file `spectrum.rom`) in `~/.mame/roms`, or point `ZX_ROMPATH` at the
folder containing it. If you have no ROM, do the Commodore 64 half and skip the Spectrum
steps; nothing else depends on it.

Put the two tools on your path so the rest of the guide is shorter:

```bash
export PATH="$PWD/gpf/target/release:$PWD/factory/tools/gpfdiff/target/release:$PATH"
gpf list
```

> **Gotcha: `gpf` finds the repo from your current directory first.** It walks up from
> wherever you run it to the `.gpf-root` marker file, and only falls back to `$GPF_ROOT` if
> there is none. Setting `GPF_ROOT` to try something in a scratch folder does nothing if your
> shell is still inside this checkout, and the command will happily create files here.
> `cd` to the scratch root first.

## 2. Run the demo: Brickfall on two machines

Brickfall is a small original paddle-and-bricks game written for this repo, so there is no
copyright question. One rule set lives in `games/brickfall/recipe/`; two independent ports
implement it: `ports/brickfall-c64` (6502) and `ports/brickfall-zxspectrum48` (Z80).

```bash
make -C ports/brickfall-c64/target check            # about 2 minutes
make -C ports/brickfall-zxspectrum48/target check   # about 20 seconds
```

Each command builds the port, then runs 11 scripted scenarios (launch left, a miss, a full
win, ...) twice each in a fresh emulator. You should see:

```
scenario             steps  samples  result    secs
full_win              3972      332  PASS      23.9
...
canary: mutated sample #2 (step 24) ball_vx 1 (was 0); rejected: MISMATCH ...
CHECK PASS: 11/11 scenarios passed, x2 runs deterministic, canary rejected, 125.1s
```

Three things worth noticing:

- **steps vs samples.** The scenario runs thousands of simulation steps but compares every
  Nth, because comparing at every step is slower and rarely finds more. `miss_dense`
  samples every step on purpose; the miss threshold was invisible at a coarser rate.
- **x2 deterministic.** Each scenario is run twice in fresh emulators and the traces must be
  identical. A harness whose answers change between runs cannot be believed.
- **canary.** The harness corrupts one expected value in memory and checks that it notices.
  A harness that cannot fail is itself reported as broken.

To play the games yourself, with your own emulator:

```bash
x64sc ports/brickfall-c64/target/brickfall.prg            # Z / X move, SPACE launches
mame spectrum -rompath ~/.mame/roms -snapshot ports/brickfall-zxspectrum48/target/brickfall.sna
```

(On the Spectrum, Z/X or Q/A move and SPACE launches; Sinclair joystick 2 also works.)

## 3. Break it on purpose

This is the part that makes the idea click. The Commodore 64 game speeds the ball up after
every tenth brick. Change that constant by one:

```bash
grep -n 'adc #\$40' ports/brickfall-c64/target/brickfall.asm     # one hit, in the speed-up code
sed -i 's/adc #\$40/adc #$41/' ports/brickfall-c64/target/brickfall.asm
make -C ports/brickfall-c64/target brickfall.prg
gpfdiff check ports/brickfall-c64 --only speedup,full_win --no-canary
```

The game still runs and looks fine; no human playtester would notice. The harness does:

```
speedup     1500      151  FAIL      12.7
    speedup: run 1/2: MISMATCH step 1140 (sample #114) field ball_y: expected 15424 got 15427
      #113  1130 1 3 150 44 8 17088 13696 -192 384 fffffbeba2
    - #114  1140 1 3 150 40 10 15168 15424 -192 448 fffffbe9a0
    + #114  1140 1 3 150 40 10 15168 15427 -192 449 fffffbe9a0
                                     ^^^^^
    differing field: ball_y (column 8 of 11)
CHECK FAIL: 2 of 2 scenarios failed (0 passed), canary skipped, 35.5s
```

(Your numbers will match these, since the simulation is deterministic.) The ball is 3/256 of
a pixel off at step 1140, the first sample taken after the tenth brick has fallen and the
speed-up has fired (the `cleared` column went from 8 to 10).
Nothing on screen differs; the trace does. The `-` line is what the reference expects, the
`+` line is what your port produced, and the caret marks the field. Exit code 1 means the
*game* is wrong. Restore it and confirm:

```bash
git checkout ports/brickfall-c64/target/brickfall.asm
make -C ports/brickfall-c64/target brickfall.prg
gpfdiff check ports/brickfall-c64 --only speedup,full_win
```

Exit code 2 would mean something different: the *environment* is wrong (an emulator is
missing, a ROM wasn't found, an emulator timed out). The two are never confused, so a script
can tell "the port is broken" from "the machine is broken".

## Port an existing game: use the original as the oracle

For your own game the oracle was a Rust model. For a game you did not write, **the original
binary is the oracle**, and it was never built to cooperate: no state block, no labels, no
test hooks. `gpfdiff` drives it from outside: it injects keys on a frame clock, reads declared
RAM addresses, and records a trace. The port is then diffed against that trace.

You can practise the whole workflow with no copyrighted game. Brickfall's Spectrum build stands
in as "an unknown original", and the repo already holds a black-box manifest for it that ignores
every label the program exports.

### 1. Start the port and read the task chain

```bash
gpf init mygame-c64 --title "My Game" --game mygame --source zxspectrum48 --target c64
gpf next mygame-c64
```

The seeded chain after the usual identify/classify tasks is five oracle tasks: (1) find the
state addresses, (2) write the field map and the ready gate and prove a capture of the original
is deterministic, (3) capture golden traces, (4) run the first `gpfdiff check` and triage every
diff, (5) write `expectations.toml` and fix real bugs until `check` passes. Add `--public` if
the port will be published (see the Dizzy chapter below); it appends the release chain.
Each task carries a tier and, where one exists, a verifier.

### 2. Scaffold the oracle

```bash
gpfdiff init-oracle ports/mygame-c64 --platform zx48 --image original.sna
```

```
wrote     ports/mygame-c64/harness.toml
wrote     ports/mygame-c64/expectations.toml
wrote     ports/mygame-c64/scenarios/example.toml
wrote     ports/mygame-c64/NEXT-STEPS.md
INIT-ORACLE OK: zx48 black-box oracle scaffold in ports/mygame-c64 (4 files)
```

It writes commented files with the key map for the platform, the frame rate, example fields
and the rules for the ready gate. Nothing is guessed: the addresses and the gate are TODOs.
It refuses to overwrite existing files, and exits 2 for c64 (the VICE backend has no keys mode,
so a Commodore 64 original cannot be driven this way yet). `gpfdiff check ports/mygame-c64
--list` already parses the scaffold.

### 3. Find the state addresses

Press a key and see which bytes move. On the Brickfall Spectrum build, hold LEFT for a second:

```bash
gpfdiff watch ports/brickfall-zxspectrum48/blackbox --region 0xF000:0xF0FF --keys "LEFT@0ms+1000ms" --frames 60
```

```
    frame          ms  addr           old -> new
    1..60    20..1200  0xF000         00 -> 3c  (0 -> 60)  x60 frames
    1..28     20..560  0xF006         70 -> 00  (112 -> 0)  x28 frames
    1..28     20..560  0xF026         70 -> 00  (112 -> 0)  x28 frames
    1..28     20..560  0xF047         70 -> 00  (112 -> 0)  x28 frames
    1..28     20..560  0xF076         70 -> 00  (112 -> 0)  x28 frames
      29         580  0xF067         01 -> 00  (1 -> 0)
520 byte changes at 18 addresses in 60 frames; 18 lines
```

Read it like a detective. `0xF000` increments every frame for 60 frames: a frame or step
counter. Four addresses move from 112 to 0 over 28 frames and then stop: the paddle hitting the
left wall. There are four because the program keeps several copies (a working value, the
published one, the last-drawn one). `watch` cannot tell them apart; **a disassembly or source can**,
which is why the prior-art sweep comes first. Pick the one the program publishes, not the one it
redraws from.

### 4. Declare fields and the ready gate

```toml
[boot]
image = "../target/brickfall.sna"
ready = { addr = 0xF046, in = [1, 254] }   # "first frame drawn"
timeout_ms = 2000

[[field]]
name = "step"
addr = 0xF000
size = 2
```

The gate decides where the timeline starts, and it must be an **observed state, never a frame
count**: title screens and loaders take a variable time. Choose it carefully. Brickfall's lives
byte is set at boot, so gating on `lives == 3` starts the clock two frames early and every
sample then lags by two steps. Gating on the byte that is 255 until the first frame is drawn is
exact. If you leave the gate out, `check` and `capture` warn that the timeline starts at the
first frame. Each `[[field]]` can carry `scale`, `offset` and `tolerance`, which is how a 4x
coordinate system or a one-pixel jitter is normalised between the original and the port.

### 5. Capture, then check

```bash
gpfdiff capture ports/mygame-c64 --scenario all --out ports/mygame-c64/harness/golden
gpfdiff check ports/mygame-c64
```

`capture` records the original's trace (twice, to prove it is deterministic) and from then on
the port is verified without the original running. Keep captured traces of a commercial game
private. The first `check` will fail: that is how you discover differences. Sort each one into
**platform physics** (a different frame rate, a monochrome screen) or **a port bug**. Name the
former in `expectations.toml` with a reason; it then reports EXPECTED instead of FAIL, and a
stale entry is warned. Fix the latter. Exit code 1 means the game is wrong; exit code 2 means
the environment is (run `gpfdiff doctor`).

To see the scaffold turn into a working oracle with only the addresses filled in:

```bash
make -C ports/brickfall-zxspectrum48/target check-scaffold
```

It scaffolds a fresh oracle, edits in just the addresses, the gate and the keys, captures all 11
scenarios, and compares them with the reference model at every sample.

## The golden example: build Dizzy from your own copy

Brickfall shows the method on an original game. *Fantasy World Dizzy* shows it on a real one:
a ZX Spectrum game reimplemented for the Tandy CoCo 2, about 240 tracked tasks deep. **The repo
contains none of the game**, yet anyone who supplies the original source files can build the
port and check the result against the author's build, byte for byte.

**What you supply** (the sha256 of every file is in `ports/dizzy-coco2/tools/inputs.toml`; the
bootstrap rejects anything that does not match and never downloads anything):

| You supply | For |
|---|---|
| The Oliver Twins' released source and data for the game, as redistributed in the `picosonic/D3` repository. It is their copyright, not MIT. The directory you pass must contain `original_source/` and `info/` | building |
| Tandy CoCo ROMs `BASIC.ROM`, `EXTBASIC.ROM`, `DSKBASIC.ROM` | running the result in an emulator |
| A Spectrum ROM (`spectrum.zip`) and a Fantasy World Dizzy `.tzx` | only the original-vs-port harnesses |

**Build it:**

```bash
cd ports/dizzy-coco2
tools/bootstrap.sh --list                                   # the 14 steps, in dependency order
tools/bootstrap.sh --d3 /path/to/your/D3 --roms /path/to/coco-roms --verify
```

It takes about 90 seconds. It checks your inputs, builds the Rust tools offline, extracts the
rooms, actors and sprites, captures the music, converts the art, fills the game's text into the
repo's public templates from *your* copy, compresses and packs everything, and writes
`target/room36.cas` (tape), `target/dizzy.dsk` (floppy) and the run build. With `--verify` it ends:

```
  match   target/room36.cas  885868ef...
  match   target/dizzy.dsk   cd17b749...
all 5 artifacts match docs/BUILD-HASHES.txt
```

If a hash differs, either an input is not the exact file the author used (the first step would
have caught that) or a tool version differs; `docs/BUILD-HASHES.txt` records the toolchain.
Play it on your own emulator: `./play.sh --tape --inf-lives` (see `docs/PLAYTEST-GUIDE.md`).

**How the repo stays free of the game.** Every file is one of three kinds
(`ports/dizzy-coco2/docs/PROVENANCE.md`):

- **Ours, tracked:** the 6809 code, all tools, the harnesses, the notes, and the text *templates*.
- **Yours, supplied:** the original source above.
- **Generated, gitignored:** everything derived from yours. Never committed.

The one hard case was the game's text, which was hand-edited source mixed with the original's
dialogue. It is split into public templates holding the code, the port's own strings and keys
(`@orig(X-ALL:296/13)`) into your `X-ALL.TXT`; the bootstrap fills the keys in. A round-trip test
proves `fill(split(x))` equals the original byte for byte, and the export refuses to publish a
template or a doc that contains running dialogue. The policy is in `NOTICE.md`.

**A pattern for any port of a game you do not own.** The same split works for yours: write the
tools that turn the user's media into build inputs, keep every derived byte out of git, give the
user one command that regenerates it and a hash list that proves they got the same result. Dizzy
is the worked example of doing that for a real game with real art, music and text.

## 4. How the pieces fit

| Piece | Where | What it is |
|---|---|---|
| Recipe | `games/<game>/recipe/README.md` | The rules, the RAM state contract, the input contract, acceptance. The spec. |
| Reference model | `games/<game>/recipe/model/` | A Rust implementation of the rules. The oracle. |
| Scenarios and goldens | `recipe/scenarios/`, `recipe/golden/` | Scripted inputs and the expected state trace the model produces. |
| Port | `ports/<game>-<platform>/` | The real thing on the real machine. Exposes `gpf_state`. |
| Harness | `factory/tools/gpfdiff/` | Drives an emulator, diffs the trace. One backend per emulator. |
| Manifest | `ports/<slug>/harness.toml` | Tells the harness which image, symbols and recipe to use. |

The harness and its backends are documented in
[`factory/tools/gpfdiff/README.md`](../factory/tools/gpfdiff/README.md): the file formats,
the `harness.toml` reference, exit codes, a troubleshooting table, and how to add a backend
for a new emulator.

## 5. Start your own port

There are two cases, and they use different commands.

### An original game (like Brickfall)

No source binary to dig through; your design is the source of truth.

```bash
gpf init mygame-c64 --title "My Game" --game mygame --target c64 --original
gpf status mygame-c64        # the handoff note and what to do next
gpf next mygame-c64          # the next task, its tier, and its verifier
```

`--original` seeds a task list for this case: write the recipe, build the reference model,
stand up the target toolchain, build the harness, then a vertical slice, then polish. The
recipe task is tiered `opus` because no machine can check a design; most of the rest carry
a verifier so they can be handed to cheaper models or scripts. Copy
`games/brickfall/recipe/README.md` as your starting point: the integer-only, fixed-step,
no-RNG discipline there is what makes a bit-exact oracle possible.

Rules of thumb that took real effort to learn:

- **One state block, fixed layout.** Every port exports `gpf_state`; the harness finds it
  through the assembler's symbol file, never a hard-coded address.
- **Inject input where it is read.** Brickfall exports a label at the end of its input
  routine; the harness stops there and overwrites the result. No test-only code path ships.
- **Sample densely where thresholds matter**, and mutate your own code to prove the checks
  can fail (section 3).
- **Make art and sound additive.** Freeze the simulation first, then check it still matches
  after every polish change.

### An existing commercial game

```bash
gpf init mygame-c64 --title "My Game" --game mygame --source zxspectrum48 --target c64
```

This seeds the full stage model: identify, classify, excavate, recover, scaffold, slice,
iterate, with the oracle chain described in
[Port an existing game](#port-an-existing-game-use-the-original-as-the-oracle). **Do not skip classify**: whether source exists and whether the target is at least
as capable decides which of three strategies you use, and the strategies differ in cost by
orders of magnitude. Read [`docs/STRATEGY.md`](STRATEGY.md) before that stage and
[`docs/STAGES.md`](STAGES.md) for the exit criterion of each.

Two ground rules for this case:

- **Work only from media you own.** Originals and anything derived from them (converted art,
  music, level data, tape and disk images) stay out of git. [`NOTICE.md`](../NOTICE.md)
  explains what this repo does and does not distribute, and the `.gitignore` carries a guard
  for the common formats.
- **Search for prior art before writing a converter.** The best result of a session is often
  finding that the work was already done.

[`ports/dizzy-coco2`](../ports/dizzy-coco2) is a real, large example of this case (a ZX
Spectrum game reimplemented on the Tandy CoCo 2), and it is the model for keeping a
commercial game out of git: see [the golden example](#the-golden-example-build-dizzy-from-your-own-copy)
above for how it builds from files you supply. Its `NOTES.md` is the best record of what
the process looks like at scale, including the dead ends.

## 6. Working with Claude Code

The intended way to use this repo is to talk to Claude Code inside it. `CLAUDE.md` loads
automatically and carries the session protocol: read the state first, do one task at a time,
record findings and dead ends, and end every session with `gpf harvest` and `gpf handoff`.
Sessions are expected to be episodic and weeks apart, so the handoff is the deliverable.

Your jobs are to decide the judgement calls, supply media you own, approve installs, and
stop whenever you like. [`docs/OPERATING.md`](OPERATING.md) is the full guide, including how
to match work to the time you have. [`docs/COST-MODEL.md`](COST-MODEL.md) explains tier routing: work
goes to the cheapest model that a cheap deterministic check can prove correct.

## Commands you will use

```bash
gpf list                      # every port and where it stands
gpf status <slug>             # handoff note, blockers, next task
gpf next <slug>               # the single next task, with tier and verifier
gpf task add <slug> --stage S --title T --tier sonnet --verify 'cmd'
gpf task edit <slug> <id> --verify 'cmd' --tier haiku
gpf task start|done <slug> <id>
gpf decide --title ... --axis ... --because ... --precondition ...   # a reusable decision
gpf harvest <slug>            # end of session: what did this teach the factory?
gpf handoff <slug> "..."      # end of session: what the next one does first

gpfdiff doctor --platform all
gpfdiff check ports/<slug> [--only a,b] [--list] [--json]
```

## When something goes wrong

- **`gpfdiff` exits 2.** The environment, not your game. Read the message: it names the
  cause and the next command to run, usually `gpfdiff doctor`.
- **A scenario FAILs.** Read the first differing line: step, field, expected, got. Re-run just
  that scenario with `--only name --debug`. Check it is deterministic before chasing it.
- **MAME or VICE hangs or times out.** Run scenarios one at a time (the harness already
  does); a parallel batch can exhaust memory. `--timeout` raises the per-step wait.
- Everything else: the troubleshooting table in the
  [`gpfdiff` README](../factory/tools/gpfdiff/README.md#troubleshooting), built from the real
  dead ends in this project.

## Where to go next

| I want to... | Read |
|---|---|
| Understand the stage model | [`docs/STAGES.md`](STAGES.md) |
| Pick a strategy for an existing game | [`docs/STRATEGY.md`](STRATEGY.md) |
| See how work is routed to cheaper tiers | [`docs/COST-MODEL.md`](COST-MODEL.md) |
| See how the factory improves itself | [`docs/SELF-IMPROVEMENT.md`](SELF-IMPROVEMENT.md) |
| Browse reusable decisions | `factory/recipes/` (each states its precondition) |
| Add a new target platform | `factory/platforms/*.toml` and `gpf platforms` |
| Add a new emulator backend | `factory/tools/gpfdiff/README.md`, "Adding a backend" |
