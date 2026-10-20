# Diff two builds across every start position, don't hand-write a route test

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-06

## Decision

A hand-written jump test holds a direction and re-jumps on a cycle, so it measures 'possible in unlimited attempts', not 'reachable'. Three such tests cleared T0082 wrongly while the playtester could not finish the room. Replaying one fixed input script from every walkable start in the room and diffing the outcome tables found the regression in a single run, two surfaces away from where all three tests looked.

## Precondition

A behavioural regression is reported against a build you can still assemble the previous version of, and the failing route is not known with certainty.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
