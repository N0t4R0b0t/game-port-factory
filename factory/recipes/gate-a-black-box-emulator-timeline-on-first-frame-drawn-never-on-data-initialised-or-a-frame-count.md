# Gate a black-box emulator timeline on 'first frame drawn', never on 'data initialised' or a frame count

- **axis:** `raster` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-10-20

## Decision

A gate that fires early (e.g. lives==3, set at boot) starts the clock before the first frame and every sample lags by the gap; a byte that is 255 until the first draw is exact. Found with gpfdiff watch --no-gate

## Precondition

The original does not cooperate (no labels or hooks) and you can observe RAM; fails if no RAM byte changes at the first draw, then gate on a state the program reaches only once idle in its main loop

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
