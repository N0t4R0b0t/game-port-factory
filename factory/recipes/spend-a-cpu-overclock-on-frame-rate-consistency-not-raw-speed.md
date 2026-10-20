# Spend a CPU overclock on frame-rate consistency, not raw speed

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-31

## Decision

A retro port's target frame rate is set by the ORIGINAL game's pacing, not by the target machine's ceiling. Once measured throughput exceeds the original (here 27.6/sec vs the ZX version's 16.7), extra speed makes the game play wrong, not better. Give the surplus back as a wall-clock-referenced wait so the rate is scene-independent instead of drifting with scene complexity.

## Precondition

Measured throughput exceeds the original's update rate, AND the target has a clock source independent of the CPU speed change (here the VDG 60Hz field rate, which the SAM rate bits do not affect). Does NOT hold without headroom: unconditional waits cost full time even on a short pass -- measured 13.3 -> 9.6/sec when the same pacing was left on with the overclock off.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
