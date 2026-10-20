# Pacing a loop on a latching vsync flag: poll inside the work, carry the surplus, check before waiting

- **axis:** `raster` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-03

## Decision

A 'wait for the vsync flag' at the end of a frame is not pacing when the flag is a latch (PIA CB1 on the CoCo, and the same shape on many 8-bit machines): once the frame's work exceeds one field the flag is already set on arrival, the wait returns immediately, and the loop free-runs at whatever each scene costs. Because the flag latches rather than counts, a boundary that passes mid-frame is indistinguishable from ten, so elapsed fields must be sampled from INSIDE the frame's own long-running loops. Two non-obvious details decide whether the result is actually even: carry the surplus fields into the next frame instead of clearing the counter (clearing lets the frame phase drift against the field, so constant work straddles N boundaries sometimes and N+1 others), and test the budget BEFORE waiting (waiting first costs a whole extra field whenever the work already met the budget).

## Precondition

A game loop on hardware with a periodic sync flag but no usable interrupt or free-running timer -- e.g. interrupts deliberately masked, or vectors unavailable because of a memory-map mode. If a real interrupt-driven tick IS available, use that instead; it is what the original games do.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
