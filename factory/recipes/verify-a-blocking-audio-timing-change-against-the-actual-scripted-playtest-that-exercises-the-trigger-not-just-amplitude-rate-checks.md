# Verify a blocking-audio timing change against the actual scripted playtest that exercises the trigger, not just amplitude/rate checks

- **axis:** `audio` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-11

## Decision

A mainloop rate check (rate.lua) can stay perfectly clean while a specific scripted-teleport-then-act test still breaks -- the regression is in relative frame timing inside one script's fixed windows, not overall throughput. Confirmed as a real regression only by rebuilding the pre-change source and re-running the identical script (dizzy-coco2 T0089), not by assuming the new number was safe from its byte/ms size alone.

## Precondition

Any change adds or changes blocking (CPU-time-consuming) behavior on a path a playtest script drives with fixed frame-count key-press windows

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
