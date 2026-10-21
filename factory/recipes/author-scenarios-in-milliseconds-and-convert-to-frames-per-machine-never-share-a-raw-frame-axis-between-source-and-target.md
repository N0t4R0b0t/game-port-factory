# Author scenarios in milliseconds and convert to frames per machine; never share a raw frame axis between source and target

- **axis:** `raster` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-10-20

## Decision

Source and target run at different rates (50 vs 60 Hz); a shared frame axis silently desyncs, ms convert per side with consistent rounding and an optional input latency knob

## Precondition

Source and target frame rates differ, or a port's step is not one frame (a fixed-step accumulator); fails for programs whose input is sampled irregularly, where only a state-gated step clock works

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
