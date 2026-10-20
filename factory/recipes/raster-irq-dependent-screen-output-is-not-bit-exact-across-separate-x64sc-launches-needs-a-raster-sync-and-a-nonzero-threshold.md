# Raster-IRQ-dependent screen output is not bit-exact across separate x64sc launches — needs a raster sync and a nonzero threshold

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-22

## Decision

isobanks.asm (T0047) is the first program in this project to depend on precise raster-IRQ timing (chained interrupts switching $D018 mid-frame). Unlike every other verified program so far, its output was NOT bit-identical across separate harness run invocations of the same .prg -- a handful of pixels at the raster-split seams differed run to run. Root cause: the exact CPU cycle CLI executes on (and therefore which raster line the IRQ-enable window lands on) depends on how many cycles the autostart LOAD+RUN sequence burned before reaching that point, which is not identical across separate emulator launches even though the .prg is byte-identical. Reduced (not eliminated) by adding a raster-line-0 sync loop before arming the IRQ chain, cutting jitter from whole-frame differences down to ~10-14 pixels confined to the two seam rows.

## Precondition

Any future program in this project whose visual output depends on raster-IRQ timing (not just running with interrupts enabled, but actually depending on WHICH raster line an event lands on) should (a) add a raster-line-0 sync loop before arming its IRQ chain, matching isobanks.asm's approach, and (b) budget its harness check target's --threshold above the real measured jitter with a wide safety margin, not 0.0 -- the project's default exact-match convention (every non-raster-IRQ program achieves genuine byte-identical determinism) does not hold here. Size the threshold against an actual measured regression's diff magnitude, not a guess, so it still catches a real failure.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
