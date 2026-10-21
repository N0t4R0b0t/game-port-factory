# Drive an unlabeled original by injecting keys through the emulator's own input ports on a frame clock, not with breakpoints

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-10-20

## Decision

Breakpoints and register writes need a cooperating program (a label at the input routine); input ports work on any binary and need no test-only code, and the timeline is deterministic from the ready gate

## Precondition

The original cannot be modified or labelled; fails when the emulator has no scriptable input ports for the platform (the VICE backend has none today, so c64 originals cannot be driven black-box)

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
