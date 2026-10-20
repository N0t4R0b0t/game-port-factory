# Profile with a write-tap on a phase marker, not by ablation

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-04

## Decision

Stamping a phase id into one byte and timestamping the writes with the emulator's own clock yields exact per-phase microseconds in a single run. Ablation (remove a phase, diff the frame rate) is quantised by any frame pacing, contaminated by whatever else varies between runs, and gives no signal when a substitution silently fails -- it produced confident nonsense twice on this port before the tap replaced it. Cost is a few cycles per marker, compiled out of shipping builds.

## Precondition

The emulator can install a write tap or watchpoint with a callback (MAME lua can; keep the returned handle referenced or the GC removes the tap silently) and the target has a spare RAM byte

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
