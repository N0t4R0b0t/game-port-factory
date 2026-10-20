# Game Port Factory — agent instructions

A **resumable state machine for game porting projects**. Sessions are episodic and weeks
apart, so you will usually arrive with **zero memory** of previous work. That is the normal
case, not a failure — everything you need is on disk.

Two things are being built at once: **the port** (track 1) and **the factory** (track 2).
Neither is optional in any session.

## First 60 seconds

```bash
gpf list                    # what ports exist and where they stand
gpf status <slug>           # handoff note, blockers, next task — READ BEFORE ANYTHING ELSE
```

Then read `ports/<slug>/NOTES.md` for durable findings, and `gpf next <slug>` for the task
with its tier and verifier.

If `gpf` is not found: `cargo build --release --manifest-path gpf/Cargo.toml`, then use
`gpf/target/release/gpf`. It resolves the repo by walking up to the `.gpf-root` marker, or
via `$GPF_ROOT`.

**If the user asks to start something new**, don't improvise a layout:
`gpf init <slug> --title "<Title>" --game <game> --source <plat> --target <plat>`.
It seeds the opening tasks, already tiered. Platform ids come from `gpf platforms`.

## Which document to read when

Read the one you need. Do not read them all at the start of every session.

| Read this | When |
|---|---|
| `docs/STAGES.md` | You need the stage model or an exit criterion |
| `docs/STRATEGY.md` | **Before any stage-2 work.** Determines project cost |
| `docs/COST-MODEL.md` | Before delegating anything, or when routing a task's tier |
| `docs/SELF-IMPROVEMENT.md` | Track 2: tools, recipes, dead ends, transfer axes |
| `docs/OPERATING.md` | The human's guide — read it to know what they expect of you |

## Session protocol — non-negotiable

**End of every session, without exception:**

```bash
gpf harvest <slug>          # track 2: what did this session teach the factory?
gpf handoff <slug> "<what the next session does first, plus any half-finished state>"
git add -A && git commit -m "<slug>: <what changed>"
```

A session that ends without a handoff has **destroyed its own value** — the next one
re-derives what you already knew. Treat the handoff as the deliverable, and write it so a
stranger could act on it.

## Two tracks, always

- **Tools**: build inside `ports/<slug>/tools/`. Promote to `factory/tools/` only on the
  **second** port that needs them. Never the first — one caller cannot tell you the right
  interface.
- **Decisions**: `gpf decide`, always with the precondition. A recipe without one is a
  cargo cult and is marked unsafe.
- **Dead ends**: into `NOTES.md`, **with the reason**. Unrecorded dead ends get retried in
  full by a session with no memory of the first attempt.
- **Friction in the factory itself**: fix it now, or file a task. The factory is the other
  deliverable.

Before starting a port, check what already exists: `ls factory/tools/ factory/recipes/`,
and `gpf transfer <earlier-target> <this-target>` for what should carry rather than be
rebuilt.

## Rules that matter

1. **Durable findings go in `NOTES.md`, not in your reply.** Format layouts, addresses,
   memory maps, magic numbers, dead ends. If re-deriving it in three weeks would annoy you,
   write it down.
2. **One task at a time.** `gpf task start <id>` before, `done` after. New work discovered
   mid-task gets `gpf task add`, not silent scope expansion.
3. **Never skip stage 2 (classify).** Wrong strategy is the most expensive available
   mistake. `docs/STRATEGY.md`.
4. **Prior art sweep is not optional**, and it depends on nothing. Before writing a
   converter or disassembling anything, search for existing decomps, source releases,
   format docs, and prior ports. The best outcome of a session is often discovering the
   work is already done.
5. **Vertical slice before breadth.** Something running on the target early, then grow it.
   Never build three subsystems before running any of them.
6. **The differential harness earns its cost early.** Without it every iteration needs
   human eyes, and unattended progress is impossible.
7. **This repo often has more than one Claude session working it at once** (the user runs
   parallel sessions on different ports or tasks). Before `git stash`/`git stash pop`, or
   rebuilding shared generated files (`tools/stage_pack.sh`, `coco_playtest.sh`, anything
   under a port's `target/`), run `ListAgents` and check for a live peer. If one is active,
   don't touch the shared checkout for that work — use an isolated
   `git worktree add --detach <path> master` instead (symlink the port's gitignored
   `source/`, `extracted/`, and `research/**/info/` dirs into it; git won't check those
   out). Coordinate over `SendMessage` before and after anything that could touch a peer's
   files, even indirectly. If a collision happens anyway, ask whether they have a backup
   (branch/stash) and restore from that, verified with a full `git diff --stat` against it
   — don't guess.

## Game vs target

Stages 1–4 run **once per game** and produce the platform-neutral recipe in
`games/<game>/recipe/` — rules, tables, dialogue graph, quest state, asset budget.
Stages 5–7 run **once per target**, in `ports/<game>-<platform>/`.

The second target is cheaper for logic and narrative, and **no cheaper for art or
platform-native optimisation**. Say so when planning, so nobody is surprised at target #2.

## Delegation and cost

Full rules in `docs/COST-MODEL.md`. The short version:

**Delegation is the default, not an option.** The user expects the top-tier session to
plan, decide and review, and to hand execution down to cheaper models so token use stays
reasonable. Before doing a step yourself, ask whether a cheaper tier could do it against a
check. If it could, delegate it. In particular:

- **`gpf-grunt` (haiku):**
  - running harness and regression batches and collecting their verdicts, with the compare
    script as the verifier;
  - re-running changed cases to separate flaky results from real ones;
  - collecting traces;
  - diffing logs against a baseline.
- **`gpf-scout` (haiku):** hunting through large sources, disassembly or NOTES for labels,
  constants and prior findings.
- **`gpf-builder` (sonnet):** writing or extending test tools and harness scripts from a
  clear spec.
- **Local models (ollama):** summaries and bulk text.

Keep at the top: diagnosing why the port diverges, choosing the fix, anything the user
must decide, and reviewing what comes back. Doing mechanical work inline is the
exception. Justify it by the context cost of explaining the job, never by habit, and
batch small steps into one delegated job rather than running them inline one at a time.

**Route by verifiability, not difficulty.** Ask whether a cheap deterministic check proves
the output correct. If yes, push it down a tier aggressively. If no, keep it at the top —
a weak model that hits a wall produces confident wrong output, and the cheap attempt plus
the expensive fix plus the downstream damage costs more than never delegating.

- Agents: `gpf-scout` (haiku, read-only recon), `gpf-grunt` (haiku, verifiable mechanical
  work — refuses tasks with no verify command), `gpf-builder` (sonnet, writes tools *and
  the tests cheaper tiers run*).
- Tasks carry `--tier` and `--verify`. `gpf next` warns when a verifier is missing.
- Wall hit: `gpf task escalate <slug> <id> --reason "..."`. The reason carries into the
  task note so the next tier doesn't restart cold.
- Top tier keeps: strategy, design reduction, art direction, asset budgets, recipe schema.
- **Prefer parallel fan-out over a smaller model.**
- Local models (ollama) for bulk text; **local vision models** are the free verifier for
  sprite readability. Use the HTTP API — the CLI corrupts piped output. Never ask the local
  tier to recall platform facts; those live in `factory/platforms/*.toml` as data.
- Delegation has overhead. If establishing context costs as much as the task, do it inline.

## Scope the verification to the change

**Test what changed and what it touches. Nothing else.** A full regression
run happens in exactly two cases:

1. **The user asks for one.**
2. **The change is profound enough to affect the whole app** -- the memory
   map or block layout moves, the packer/unpacker or another cross-cutting
   mechanism changes, symbols shift between passes, or several unrelated
   changes land together.

Everything else gets a scoped check: **the harness that reproduces the
thing you fixed, plus the build-time guards, plus whatever that code path
directly feeds.** That is the whole verification. Running the suite "to be
safe" is not safe -- it is expensive, and a suite this size will eventually
hand you a false FAIL that costs more than it ever saved.

- **Artifact-level checks beat behavioural ones and cost ~nothing.** If the
  rebuilt binary is byte-identical outside the region you touched
  (`cmp`/`diff` against the previous build, block table dumped from the
  file), no emulator harness can tell you anything new. Do that first; if
  it is clean, the behavioural suite is *provably* uninformative.
- **A FAIL from a delegated batch is a claim, not a result.** Check it was
  invoked correctly before chasing it -- ask the agent for the exact
  command line and re-run the one failing case yourself. Two of this
  repo's harnesses have reported failures they had not found (NOTES.md
  T0172 postscript).
- **Time-box a false-alarm chase.** If two rounds do not reproduce against
  a clean artifact diff, stop and say so rather than running the emulator
  again.

## What the user expects of you

- **Bring them decisions, not tasks.** If you are asking them to do mechanical work, that
  is a routing failure. Legitimate asks: which strategy, how much detail to cut, what the
  asset budget is, approval for a pull or install.
- **Ask before**: pulling a model, installing anything, or anything that leaves the machine.
- **They may stop at any moment.** Keep the handoff current enough that this is always safe.

## Tooling and posture

- **Rust** for converters, extractors, harness. Not Python.
- Wrap existing tools (QuickBMS, Ghidra headless, emulator CLIs) rather than reimplementing.
- If you change `gpf` itself, rebuild and re-test before handing off — a broken CLI blocks
  the next session completely.
- Work only from dumps of media the user owns. Converted assets stay out of public repos.
  For anything shareable, prefer targets with released source (RTCW, Quake 3, Doom 3).
