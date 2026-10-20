# Generate a map document from the engine's own room-numbering rule

- **axis:** `storage` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-04

## Decision

A room number is meaningless three weeks later and sessions were referring to rooms as 'the one with the stairs', which cannot be searched and can match the wrong room. Many 8-bit engines have no exit table at all -- Fantasy World Dizzy's entire map is four routines doing roomno +/- 1 and roomno +/- 16 with an and-127 -- so the topology is recoverable in minutes and the names usually already sit in the extracted room data. Generate it rather than writing it by hand, so it tracks what the port has actually built.

## Precondition

The engine derives neighbours arithmetically or has an exit table, and room/level names are extractable; state adjacency separately from reachability, since on a grid engine every room has four arithmetic neighbours and the art decides which are walkable

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
