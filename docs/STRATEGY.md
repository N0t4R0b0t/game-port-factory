# Stage 2 — choosing a porting strategy

Two questions decide the cost of the entire project. Answer them honestly before
committing, because the three strategies are **not interchangeable** and switching
later means throwing the work away.

### Q1. Does usable source exist?

Released source, a completed decompilation, or a substantially complete disassembly.
A *partial* decomp does not count — check the actual completion percentage, not the
README's optimism.

### Q2. Is the target at least as capable as the source?

Compare honestly: CPU throughput, RAM, storage budget, and — most often overlooked —
**GPU paradigm**. A tile-based deferred renderer and an immediate-mode renderer are not
substitutable by translation.

## The decision

| Source? | Target ≥ Source? | Strategy | Cost |
|---|---|---|---|
| yes | yes | `source-port` | weeks |
| no | yes | `recompile` | months |
| either | **no** | `reimplement` | months → years |

### `source-port`
Retarget existing code. Cheapest by an order of magnitude. If you land here, most of the
excavate/recover stages collapse to "read the code."

### `recompile`
Static recompilation of the original binary (the N64Recomp / PS2Recomp lineage).
**Only viable when the target has headroom**, because recompilation *translates* rather
than optimises — it spends performance to avoid understanding the code. Recompiling onto
a weaker target is not a slow path, it is an impossible one.

### `reimplement`
Assets convert; logic is rewritten against the original as reference. This is the honest
answer whenever the target is weaker, or the CPU family differs, or the graphics hardware
has no analogue. Be clear with yourself that this is a **remake with excellent reference
material**, not a port, and scope accordingly.

## Worked examples

**RTCW → modern engine.** Source is GPL-released; target is vastly more powerful.
→ `source-port`. Prior art: iortcw, ET:Legacy. Weeks to first light.

**C64 → ZX Spectrum 48K.** No source; different CPU family entirely (6510 vs Z80, zero
instruction reuse); no hardware sprites on the target, so everything becomes masked
software blitting against attribute clash; 48K means **beeper only**, no AY.
→ `reimplement`. Tractable for a small game. Assets convert, logic and audio get rewritten.

**PS2 → Dreamcast.** No source. Target is *weaker on every axis*: 16MB vs 32MB RAM,
SH-4 vs R5900 plus two vector units, tile-based deferred vs immediate mode, 1.2GB GD-ROM
vs 4.7GB DVD. Recompilation is ruled out by the capability inversion; matching decomps run
for years per game.
→ `reimplement`, and honestly: a research project, not a factory job. Pick a different
target or a different game.

## Recording the decision

```bash
gpf strategy <slug> <source-port|recompile|reimplement>
```

Then write **why** into `NOTES.md`, including the answers to Q1 and Q2 with actual numbers.
A future session must be able to challenge the decision without redoing the research.
