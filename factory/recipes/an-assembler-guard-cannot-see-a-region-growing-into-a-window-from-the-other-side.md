# An assembler guard cannot see a region growing into a window from the other side

- **axis:** `memory_tier` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-07

## Decision

The staging-overflow guard checks staged block sizes against their windows with ifgt. It could never catch the resident code region growing past its end INTO a staging window -- only a check against the emitted DECB blocks (memaudit) sees that. Two different failure directions need two different checks.

## Precondition

A layout with fixed windows written from both sides. Keep the block-level audit even after adding an assemble-time guard; they cover opposite failures.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
