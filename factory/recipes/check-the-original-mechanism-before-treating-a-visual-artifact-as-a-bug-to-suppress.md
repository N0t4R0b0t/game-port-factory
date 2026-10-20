# Check the original mechanism before treating a visual artifact as a bug to suppress

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-11

## Decision

The portcullis's trail was READ as a leftover-sprite bug by a previous session and suppressed with an erase-then-draw fix, when the source's own routine (printmoving, not rubprintmoving) deliberately never erases -- the trail IS the mechanism, the gap becomes a solid column after one full rise. Suppressing it produced a visually-plausible but functionally wrong gate (a hopping 8x8 block instead of a rising column) that shipped and played for at least one prior session before being caught.

## Precondition

Anything that looks like a rendering artifact (a trail, a stale frame, a flicker) in a port of a game with disassembled/documented source. Check what the SOURCE ROUTINE actually does before 'fixing' it -- the artifact may be the intended mechanic, not a bug.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
