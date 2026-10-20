# Cost model — routing work to the cheapest tier that can do it

## The trap in the obvious design

The intuitive rule is "give simple tasks to small models." It fails, because **a weak model
that hits a wall usually does not know it.** It produces confident, plausible, wrong
output. So the naive tiering sequence is:

1. pay for the cheap attempt
2. pay for the expensive tier to redo it
3. pay a third time to undo the damage the wrong answer caused downstream

That is more expensive than never delegating at all. Self-reported confidence cannot be
the gate, because the models least able to do the work are also least able to judge
whether they did it.

## The rule that actually works

**Route by verifiability, not by difficulty.**

The question is never "is this task simple enough for haiku?" It is:

> Is there a cheap, deterministic check that proves the output is correct?

If yes — delegate aggressively, even for hard work. A wrong answer costs one cheap retry
and is caught by machine.

If no — the task belongs at a high tier regardless of how simple it looks, because errors
are silent and compound.

This is why `gpf task add` takes `--verify`, and why `gpf next` prints
`verify: NONE — do not push this below its tier` when it's missing. A task without a
verifier is not a candidate for delegation, full stop.

## The cheapest tier is not a model

Before routing anything to `local`, ask whether it needs a **model at all**. There is a tier
below every model in the table, and it is the one most often skipped:

| Tier | Cost | Correctness |
|---|---|---|
| **`none` — deterministic code** | ~free | **correct by construction** |
| `local` (ollama) | free, slow | needs a verifier |
| `haiku` / `sonnet` / `opus` | metered | needs a verifier |

Counting, sorting, summing, percentiles, byte offsets, format conversion, hashing, diffing —
these are `awk`, `sort`, or twenty lines of Python. A model asked to do arithmetic over a
corpus is slower, costs tokens, and can be *wrong*, whereas a script cannot be wrong about a
sum. Routing such work to a model is a category error, not a cost optimisation.

**Observed 2026-08-12** (fallout1-c64 fan-out): of four tasks dispatched to subagents, two —
dialogue size distribution, and reading a `u32` at a fixed offset in six files — were pure
computation and should have been shell one-liners. They were routed to `haiku` reflexively
because "delegate the cheap stuff" was mistaken for "delegate the cheap stuff *to a model*".

### Where models start earning their place

The boundary is **semantic judgement over volume**:

- classifying 1,950 dialogue files as major-NPC vs minor-bark -> **local**, forced-choice
- judging whether a 12x21 sprite reads as a human figure -> **local**, forced-choice
- deriving binary field order from a reference implementation -> **sonnet+**
- deciding what invariant would prove those offsets correct -> **sonnet+**

Note the split inside a single task: sizing the dialogue cut is *arithmetic* (script) plus
*importance classification* (local model). Splitting a task along that seam is usually better
than routing the whole thing to one tier.

## The tiers

| Tier | What belongs there | Verifier |
|---|---|---|
| `local` (ollama) | Bulk text: summarising files to decide relevance, extracting lists, normalising, first-pass triage of search results. Output used as a *filter*, where a mistake is cheap. | Schema validation, or errors are self-correcting downstream |
| `haiku` | Batch conversion driving an existing tool, mechanical code transforms, collecting harness numbers, applying a specified transform to N files | Build passes, tests pass, round-trip within tolerance |
| `sonnet` | Writing new converters and harness pieces, reverse-engineering a documented format, implementing a subsystem from a spec, prior-art sweeps | Tests it writes itself, reviewed by the caller |
| `opus` | Strategy classification (stage 2), design reduction, art direction and asset budget, recipe schema design, anything where being wrong is silent and expensive | **None exists — that's why it's here** |

The top tier is defined by the *absence* of a verifier, not by difficulty. "How much detail
do we cut from a 12×21 sprite" is not a hard computation; it is a judgement with no
machine check and expensive consequences, so it stays at the top.

## Escalation

Recursive, and it must carry context or it is just a retry at a higher price.

```
gpf task escalate <slug> <id> --reason "<what specifically was the wall>"
```

This bumps the tier one step, increments `attempts`, resets the task to `todo`, writes the
reason into the task note, and appends to `factory/escalations.log`.

The subagent definitions in `.claude/agents/` enforce the other half: every tier returns
exactly one verdict — `VERIFIED`, `FAILED_VERIFY`, `ABSENT`, or `BLOCKED <reason>` — and is
told explicitly never to guess past a wall. The verifier is still the real gate; the
verdict is a courtesy that saves a round trip when it's honest.

At the top tier, escalation fails loudly: there is no model above, so it needs a human.

### Escalations are the feedback signal

`factory/escalations.log` is the routing table's training data. A task class that keeps
escalating from `local` to `haiku` was mis-tiered — fix the default rather than paying the
escalation every port. This is track 2 applied to cost, and it's the mechanism by which
the factory gets cheaper as well as faster.

## Two honest warnings

**Delegation has overhead.** Every subagent starts cold and re-derives context. For small
tasks, that setup costs more than doing the work inline. Rule of thumb: **if establishing
the context is comparable in size to the task, don't delegate.** Tiering pays when the
chunk is large, self-contained, and verifiable.

**Parallel fan-out beats tiering.** The bigger win is not "cheaper model for this task",
it's "twelve independent verifiable conversions running at once." That helps wall-clock and
cost together. Reach for breadth before reaching for a smaller model.

## The local tier, specifically

Installed and confirmed working, including structured JSON output.

- **Use the HTTP API, not the CLI.** `ollama run` emits ANSI spinner escape codes that
  corrupt piped output. Use:
  `curl -s http://localhost:11434/api/generate -d '{"model":"qwen2.5:7b","prompt":"...","stream":false,"format":"json"}'`
- Nothing stays loaded between calls, so the first request pays a model-load cost. Batch
  work into one process rather than many small calls.
- `gpf models` reports what is installed, what this hardware can actually run, and what is
  worth pulling. It never pulls on its own: **ask the user first**, then
  `gpf models --pull <name>`, which re-checks resources and refuses anything that cannot
  fit. Add candidates to `factory/models.toml` with a size and a reason — `--pull` only
  accepts roster entries, so nothing arrives undocumented.
- Verdicts are `fits GPU` / `fits GPU if idle` / `CPU/partial — slow` / `won't run` /
  `NO DISK`, judged against free VRAM, total VRAM, available RAM, and free space at the
  resolved store. Note the store is **not** `~/.ollama` when ollama runs as a service —
  here it is `/var/lib/ollama`.

### Worked example of the trap — from the first live test

Asked `qwen2.5-coder:7b` for the C64 hires hardware sprite dimensions, `format=json`:

```json
{"width": 256, "height": 192}
```

Well-formed. Confident. Wrong — that is the ZX Spectrum's *screen* resolution; a C64 hires
sprite is 24x21. The JSON schema check passes completely.

Two rules follow:

1. **"Returns valid JSON" is a format check, not a verifier.** A schema proves shape, never
   content. If the only check is structural, the task is not safely delegable on content.
2. **Never ask the local tier to recall platform facts.** Hardware constants live in
   `factory/platforms/*.toml` as data. Look them up; do not ask a 7B model to remember them.
   Tier 0 is for transforming text you hand it, not for being a reference.

### Vision tier: discrimination works, identification does not

**Tested 2026-08-12** with a deliberate 24x21 humanoid sprite (unmistakable to a human:
head, torso, outstretched arms, legs) against a random-noise control at the same size.

**Open-ended prompt** — *"does it depict a recognisable subject?"*:

| | figure | noise |
|---|---|---|
| `qwen2.5vl:7b` | "nothing recognisable", confidence **0.95** | "nothing recognisable", confidence 0.95 |

Zero discriminative power, and note the 0.95 confidence on a plainly wrong answer — the
cost model's central claim, demonstrated again on the vision side.

**Forced-choice prompt** — *"Choose ONE: (A) a human figure, (B) random noise"*:

| | figure | noise |
|---|---|---|
| `qwen2.5vl:7b` | A | B |
| `minicpm-v` | A | B |
| `llava:7b` | A | B |

All three, perfect, on the identical images.

**So the readability harness must be built as forced choice or A/B comparison, never as
"what is this?"** Ask "does this read as a human figure, yes or no", or "which of these two
sprites reads more clearly" — never an open question. The capability is real; the naive
prompt shape hides it completely.

This generalises beyond vision: at tier 0, **convert judgement into selection**. A small
model choosing between supplied options is far more reliable than the same model producing
an answer from nothing.

### A verifier must be tested against a known-bad input

Building the C64 differential harness (fallout1-c64, 2026-08-12) I gave the pixel diff a
"reasonable" default threshold of 1%. It passed the clean build. It also **passed a
deliberate regression** — changing the on-screen text from green to red moved only **0.2001%**
of pixels, because ten characters on a 320x200 screen are a tiny fraction of the frame.

A verifier that cannot fail is not a weak verifier, it is a **rubber stamp** — and worse
than none, because it is trusted. The threshold was doing the exact thing this document
warns models about: returning a confident pass on wrong input.

Fixed by defaulting to **exact match (0.0)**, which is correct here because VICE is
deterministic — identical builds produce byte-identical frames (0 of 104448 pixels differ,
measured).

**The rule: every verifier gets tested against a deliberately broken input before it is
trusted.** Pass-on-good proves nothing on its own; the pair (passes good, fails bad) is the
minimum evidence. Applies to schema checks, round-trip tolerances and test suites equally.

### Broken on this machine

`llama3.2-vision:11b` fails to load — *"unknown model architecture: 'mllama'"*. The
installed ollama build has no mllama support. It is 7.8 GB of dead weight; either update
ollama or remove it. `qwen2.5vl:7b`, `minicpm-v` and `llava:7b` all work.

### Why vision matters here

Installed vision models — `llama3.2-vision:11b`, `qwen2.5vl:7b`, `minicpm-v`, `llava:7b`,
`moondream`.

This is the free answer to the art readability problem. The check a non-artist cannot do by
instinct — *"rendered at 1× on the real palette, does this 12×21 sprite read as a human
figure?"* — is a vision-model question, it runs locally at zero token cost, and it can run
over hundreds of candidate sprites unattended.

That makes it a strong tier-0 verifier for exactly the pipeline stage that would otherwise
be a bottleneck at the top tier. Build it early.

## On spending the whole quota

Maximising work-per-token and spending the full allowance are not in conflict, but they
resolve in a specific way: **if the tiering works, tokens stop being the binding
constraint and your decision throughput becomes it.** You will run out of decisions before
you run out of quota.

Which means the thing worth optimising is keeping a queue of decision-ready work — tasks
where the research is done, the options are laid out, and all that's missing is your call.
That is what the task graph and the handoff note are for.
