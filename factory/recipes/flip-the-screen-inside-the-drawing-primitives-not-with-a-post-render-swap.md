# Flip the screen inside the drawing primitives, not with a post-render swap

- **axis:** `raster` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-14

## Decision

dizzy-coco2 T0125: the original's upside-down world swaps screentable row pointers so every draw lands mirrored for free. A port whose blitters compute row addresses directly gets the same effect for ~2 cycles a row: start at row (SUM-y) instead of y and use a stride of -(rowbytes+width) instead of rowbytes-width -- it still fits a signed byte, so abx becomes leax b,x. A once-per-change row swap cannot work: sprites move every pass and are drawn in unflipped coordinates. Latch the flag per pass, clear it for message boxes and the banner, and verify with a byte-exact mirrored-framebuffer diff (harness/flipverify.lua).

## Precondition

the source flips only the display (logic and collision stay in normal coordinates), and the target's blitters address framebuffer rows arithmetically with a per-row stride

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
