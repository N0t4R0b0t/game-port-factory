# Framebuffer checks on a double-buffered target read only the on-screen buffer

- **axis:** `raster` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-12

## Decision

The off-screen buffer is the redraw target and can be caught cleared-but-not-repainted, and after a room change it can still hold the previous room; both made a correct gate fail its checks

## Precondition

the target draws into an off-screen buffer and flips, and the test samples memory at arbitrary frame times

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
