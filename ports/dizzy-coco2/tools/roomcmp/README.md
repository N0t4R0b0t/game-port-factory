# roomcmp -- room-by-room actor fidelity of the CoCo port against the ZX Spectrum original

Built for T0255 (polish campaign). It answers one question per room: **does every actor behave the way it does in
the original?** (position, frame, colour/mirror, timing, hazards), measured on the two machines running side by side in
MAME, with the same definition of "time" on both.

The numbers are the game's own state, read from memory: the ZX side from the original's `movingdata` records, the CoCo side
from the port's `actor_ram` / `actor_init_tape`. No pixels, no text. Nothing in a trace or a report is original dialogue.

## Why not gpfdiff

`factory/tools/gpfdiff` compares **scripted key scenarios** against a declared field map, one frame clock, one oracle trace.
It cannot express what this needs:

* the start of every scenario is "the first moment Dizzy is in room R", which only the closed-loop bots can reach
  (their route plays 100+ segments to get there); gpfdiff keys mode replays fixed key timelines;
* the two machines have different clocks that must be reconciled to a **common unit**, the *actor tick*
  (ZX main-loop run; the port runs the actors 4 per 3 passes, `actors_pass`), which is not a frame count;
* the records do not line up one to one (the port has 43 + 29 actor slots in two tables, ZX has 72 `movingdata` records
  in another order), so entities are paired by their initial data;
* a deviation needs a *kind* (match / phase offset / diverge) because many actors are free-running cycles.

It follows gpfdiff's conventions anyway: every EXPECTED deviation is named with its reason in `expectations.toml`
(a stale expectation fails), determinism is checked by recording twice, a canary proves the comparer can fail
(`cargo test`), and the exit codes mean the same (0 ok, 1 the game differs, 2 the environment is wrong).
Gap worth closing in gpfdiff (filed as a factory task): "enter room R and observe" scenarios that start from a named save state,
and a comparison unit other than the frame (here: the actor tick).

## Pieces

| file | job |
|---|---|
| `harness/playthrough.lua` (`PT_ENTRY_SAVE=1`) | either bot saves a MAME state at the first entry into every room: `entry_<R>` |
| `harness/roomcmp_lib.lua` | the actor tick on both machines (write taps; see the header), record/flame/water readers |
| `harness/roomcmp_rec.lua` | **standing-still trace**: loads `entry_<R>`, presses no key, writes N actor ticks (default 400) |
| `harness/roomcmp_log.lua` (`PT_RCLOG=<file>`) | **passive log** of a whole bot run: every record of the room Dizzy is in, as deltas, plus Dizzy's animation |
| `tools/roomcmp/` (Rust, std only) | the comparer; `roomcmp --zx A --coco B` (traces) and `roomcmp visits --zx A --coco B` (logs) |
| `tools/roomcmp.sh` | the driver: `--entries` (run both bots), per room record twice + compare, then the visits comparison |

## What is compared

Standing-still traces (per room, per paired actor, per channel): `room`, `x` (ZX x units -> `(x-32)*4` px), `y`, `frame`, `col`
(colour byte: bit 7 is the mirror), `v1` (information only: its meaning differs per routine between the machines).
Also the flame/water counters and tables (positions are compared, the counters get a phase search) and the list of message boxes.
For each channel the comparer searches the shift (in actor ticks) that makes the port's sequence equal the original's:

* `MATCH` shift 0; `match (entry-sync offset +-2)` is the same thing: the two save points differ by up to two ticks;
* `PHASE port lags N` a constant offset larger than that: same behaviour started at a different moment (usually a real
  difference in what the room entry resets);
* `DIVERGE first at tick T: zx=.. port=..` different behaviour; `best shift` says whether a shift explains most of it.

Passive logs (`visits`): for every actor and channel the *runs* (value held for N ticks) that start and end on an observed change
inside one room visit. The set of `(value, duration)` pairs must agree between the machines: that is phase-free and covers the
behaviour the standing traces cannot see (triggered actors: Armorog, the gate, lifts carrying Dizzy, Daisy...).

## Run it

    tools/tape_pack.sh; tools/tape_pack.sh        # a state only loads into the binary that wrote it
    tools/roomcmp.sh --entries                    # both bots (~5 min), then every room (~3 min), then the visits comparison
    tools/roomcmp.sh --rooms "49 53"              # re-record two rooms from the existing states
    tools/roomcmp/target/release/roomcmp --zx target/roomcmp/zx_49.trace --coco target/roomcmp/coco_49.trace --show z0/t00 --from 1 --to 60

`--show zID/portID` prints the two records tick by tick (ZX id = movingdata index, port id `bNN` base table / `tNN` tape table).
Outputs are in `target/roomcmp/` (gitignored: derived from the user's tape and ROM-loaded game).

## Reading a verdict

Not every DIVERGE is a port bug. Decide per finding: (a) port bug -> fix faithfully; (b) platform difference -> add an
`[[expect]]` with the reason; (c) design decision -> list it. A random event (the dragon's breath, the rat's turn) is (b) unless
the *rule* differs; read the routine in `X-ALL.TXT` next to the trace. `docs/ROOM-FIDELITY.md` has the per-room outcome.

## Limits (be honest about them)

* Standing still means triggered behaviour is only seen where the bots' route triggers it (visits mode).
* The port's `v1`/`v2` are not the original's `var1`; the channels compared are the visible ones. Behaviour that lives only in
  port variables (e.g. the dragon's flame positions) is compared through the frames/positions it produces, not directly.
* Sound: not compared here (the ZX plays through the AY, the port through the 1-bit DAC); see docs/ROOM-FIDELITY.md.
