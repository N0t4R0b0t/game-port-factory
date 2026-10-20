# Verify an optimization with a byte-exact framebuffer diff, and pin every animation phase first

- **axis:** `raster` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-04

## Decision

An optimization must change no pixels, and that is directly checkable: dump the displayed framebuffer at a deterministic point in both builds and compare. Making it deterministic is the whole difficulty -- pin the animation INPUTS rather than outputs (a frame index recomputed each pass just gets overwritten), pin every independent animation counter (flames, water, RNG-timed actors), park anything whose slot index can shift, and force the redraw far enough ahead of the dump that it has finished. Each of those, unpinned, produces a convincing fake difference.

## Precondition

The emulator can read framebuffer memory and inject inputs deterministically

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
