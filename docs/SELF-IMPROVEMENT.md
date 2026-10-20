# Track 2 — the factory improving itself

Every session runs **two tracks at once**:

- **Track 1** — get this port further along.
- **Track 2** — leave the factory better than you found it.

Track 2 is not a phase at the end. It is not optional. A session that advances the port
and extracts nothing has done half its job, because the expensive part of a port is not
the code — it is the judgement, and judgement evaporates between sessions.

## The three things worth keeping

### Tools
Anything executable. Converters, extractors, harness pieces, build glue.

**Rule of two: build it inside the port, promote it on the second port that needs it.**

New tools live in `ports/<slug>/tools/`. They move to `factory/tools/` only when a
*second* port actually needs them — at which point you know the real interface, because
you have two callers instead of one guess. Promoting on first use produces a generic tool
shaped entirely by a single example, which is the most common way a factory like this
fills with abstractions nobody wants.

### Recipes
Judgement calls that will recur. Recorded with `gpf decide`.

A recipe is **not** "use three colours for sprites." It is "we used three colours
*because* C64 multicolour hardware sprites give three plus transparent" — and it carries
that precondition explicitly. When a later port reaches for it, the precondition is
checked first. If it doesn't hold, re-derive.

**An unchecked recipe is a cargo cult.** The `gpf decide` command refuses to let you
record a decision without a precondition field, and marks it unsafe to reuse if you leave
it blank.

### Dead ends
The cheapest thing to record and the most expensive to lose. An unrecorded dead end gets
retried, in full, by a session that has no memory of the first attempt. Record it in
`NOTES.md` **with the reason it failed**, because "we tried X" without "and here is why it
couldn't work" is an invitation to try X again.

## Transfer axes — what actually carries between targets

The naive model says the second port of a game is cheaper. True, but useless: it doesn't
say *which parts* are cheaper. Different artifacts travel along different axes:

| Axis | What carries when two platforms share it |
|---|---|
| `cpu` | code, hand-written routines, optimisation technique |
| `raster` | silhouette and detail budget, sprite dimensions, frame counts |
| `color` | palette choices, clash strategy, dithering approach |
| `audio` | music arrangement, sfx design |
| `storage` | loading strategy, disk/tape layout, streaming design |
| `memory_tier` | scope reduction, asset budget, paging design |

Run it:

```
$ gpf transfer c64 zxspectrum48
  CARRIES    raster, memory_tier
  re-derive  cpu, color, audio, storage

$ gpf transfer zxspectrum48 zx81
  CARRIES    cpu, storage
  re-derive  raster, color, audio, memory_tier
```

Which makes the C64 → Spectrum → ZX81 chain legible in a way a single "cheaper" number
never could:

- **C64 → Spectrum** hands back your **art and design** work. Same resolution class, same
  memory tier, so silhouettes, detail budget, animation frame counts, and scope reduction
  all survive. The CPU changes completely (6502 → Z80), so **none of the code does**.
- **Spectrum → ZX81** hands back your **code**. Same Z80, same tape loading. But the
  display collapses to monochrome character blocks and memory drops a whole tier, so
  every art and scope decision has to be made again from scratch.

Two hops, two axes each, *opposite* axes. Order your targets accordingly:
`gpf plan c64,zxspectrum48,zx81`.

## Is it actually working?

Accumulation is not improvement. Watch for:

- **recipes reused vs re-derived** — if later ports keep re-deriving, the preconditions
  are written wrong, probably too specific to the port that produced them
- **tools promoted vs tools rotting** in `ports/*/tools/` — a tool that never reaches a
  second port was a port-specific tool, and that's fine; a *pattern* of them means the
  rule of two is working exactly as intended
- **sessions per stage, across ports** — the number that should actually fall

If none of these move after three ports, track 2 is producing archive, not leverage. Say
so and change it.
