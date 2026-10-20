# When headlessly verifying a continuously-running game loop (not a single-draw-then-halt program), sample the framebuffer more than once -- a single async memory read can catch a torn/mid-redraw frame that looks like a real bug

- **axis:** `raster` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-29

## Decision

A headless GDB-based framebuffer capture of room36.bin's new continuous mainloop came back looking badly broken (~5300 of 49152 pixels wrong, missing walls/torches/table) immediately after refactoring from a single draw-then-hang program into a real loop that clears and redraws every iteration. A second, independent capture a moment later came back pixel-perfect (matching every prior verification exactly). The first capture wasn't a bug -- it caught the emulated CPU mid-redraw (after the clear, before all placements finished drawing), which is only possible once there's a real unbounded loop; a program that halts after one draw can't be sampled mid-update. Nearly spent debugging time chasing a phantom regression before recognizing the pattern.

## Precondition

headlessly verifying a CoCo/emulator program via GDB memory reads (harness/capture_pmode4.sh or similar) where the program contains a real unbounded loop that repeatedly clears and redraws the screen (not a one-shot draw-then-halt test program) -- take at least two independent samples before trusting a 'broken-looking' result as a real bug, since a single async sample can land mid-frame

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
