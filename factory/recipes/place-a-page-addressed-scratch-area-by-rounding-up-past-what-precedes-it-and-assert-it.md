# Place a page-addressed scratch area by rounding UP past what precedes it, and assert it

- **axis:** `memory_tier` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-12

## Decision

(base+margin)/256 floors: a 'safe' +$C00 margin put the mixer's direct-page variables 14 bytes inside its own blob, wiping the tail of its event stream only once the room image grew

## Precondition

a direct-page or page-aligned area is placed after a variable-length blob whose start address moves between builds

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
