# The seven stages

Each stage has an **exit criterion**. Do not advance until it is met — `gpf stage` is a
declaration that the criterion holds, not a wish.

Stages 1, 3, 5 and 7 are where reusable factory machinery lives. Stages 2, 4 and 6 are
irreducibly per-game and model-intensive.

---

## 1. `identify` — what is this thing
Inventory and hash every source file. Pin exact version and region. Fingerprint the
engine and the toolchain it was built with.

Then the **prior art sweep**, which is the highest-leverage hour in the whole project:
existing disassemblies, decompilations, source releases, previous ports to any platform,
file-format documentation, modding communities. Half the value of this system is finding
out that someone already did the hard part.

**Exit:** you can name the engine, the version, and every prior effort that exists.

## 2. `classify` — pick the strategy
See `docs/STRATEGY.md`. Two questions: does source exist, is the target at least as
capable. Everything downstream depends on this answer.

**Exit:** `gpf strategy` is set and the reasoning — with numbers — is in `NOTES.md`.

## 3. `excavate` — get the data out
Unpack containers, identify formats, convert to **neutral intermediates**: glTF, PNG,
WAV, JSON. Never convert source-format directly to target-format; always go through the
middle. The intermediate is what makes the converter reusable on the next project, and
what lets you re-target without re-extracting.

Wrap existing tools rather than reimplementing them. QuickBMS alone covers hundreds of
archive formats.

**Exit:** every asset class round-trips to a neutral format and you can view/play it.

**Always produce `games/<game>/recipe/MAP.md` here**, generated, not hand-written. A room
or level number means nothing three weeks later, and a session with no memory of the last
one ends up saying "the room with the stairs" — which is not a name, cannot be searched
for, and is how two sessions end up talking about different rooms. The map wants: the
game's own topology rule (in `dizzy` the whole map is four routines doing `roomno ± 1` /
`roomno ± 16` — there is no exit table at all), the numbers with their in-game names, what
this port has built so far, and what is one step outside it. `ports/dizzy-coco2/tools/`
has `roommap` + `genmap.sh` as the worked example.

Distinguish **adjacent** from **reachable** and never claim the second unless the data
actually says so: on a grid engine every room has four neighbours by arithmetic, and
whether you can walk between two of them is decided by the room art.

## 4. `recover` — get the logic out
Disassembly, decompilation, or simply reading released source. Per-game, unavoidably
manual, the most expensive stage. Under `reimplement` you are building *understanding*,
not code — the output is documentation of game rules, not a translation.

**Exit:** you can describe the game loop, the data structures, and the rules well enough
to reimplement them.

## 5. `scaffold` — stand up the target
Toolchain, emulator, build system, and a hello-world **running on the target**. Then the
differential harness: original and port driven by the same scripted input, frames
captured, output diffed.

Build the harness *before* you need it. It is what converts "iterate on this port" from a
task requiring human eyes into one that can run unattended — which is the entire point of
this system.

**Exit:** `make` produces something that runs on target, and the harness produces a
side-by-side comparison automatically.

## 6. `slice` — smallest playable thing
One screen. One level. One character that moves. Chosen to exercise the **riskiest**
subsystem first, not the easiest one — if the renderer is the thing that might sink the
project, the slice is a rendering slice.

**Exit:** something demoable exists on the target.

## 7. `iterate` — grow it
Expand the slice, diff against the original, fix, repeat. This is the stage that consumes
the leftover-credit sessions, and the one the harness exists to serve.

**Exit:** it's a port.
