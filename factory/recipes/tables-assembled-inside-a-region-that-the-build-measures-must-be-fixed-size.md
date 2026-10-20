# Tables assembled inside a region that the build measures must be fixed-size

- **axis:** `memory_tier` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-12

## Decision

title_frags.asm lives in the low region whose spare the raw pass measures for title holes; when the title needed one more hole the table grew 4 bytes between passes and the low block overlapped the chosen hole by exactly 4 bytes

## Precondition

a multi-pass build measures free space in one pass and emits a table sized by that measurement into the same region in the next

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
