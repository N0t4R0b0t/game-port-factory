# A check target's --cycles value is a safety margin, not real playthrough duration

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-22

## Decision

Building a VICE-run recording tool (target/record.sh), assumed vaultexit-check's --cycles 90000000 reflected roughly how long the real scripted playthrough takes and sampled evenly across that whole range -- 80% of the resulting video was a static repeated ending frame. Bisected with a handful of harness run --cycles N calls at increasing N and found the entire scripted run (boot, LOAD, movement, the full combat exchange, walking to the exit, the ending) completes by ~6,000,000 cycles, not 90,000,000. A -warp-mode headless run fed by --keybuf delivers keypresses as fast as the KERNAL polls for them -- there is no human reaction-time delay between keystrokes -- so a check target's cycle budget is deliberately generous so the FINAL state is stable and correctly captured regardless of exact timing, not a measurement of how long the run actually takes.

## Precondition

Before sampling a deterministic keybuf-driven run at multiple cycle points (for a recording, a timing study, or anything else that cares about WHEN something happens rather than just the end state), scan for the real active cycle range first with a few harness run --cycles N calls at increasing N -- never assume an existing check target's --cycles value is a duration measurement just because it's a real, working number.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
