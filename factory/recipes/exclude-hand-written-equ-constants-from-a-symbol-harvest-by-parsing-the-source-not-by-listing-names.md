# Exclude hand-written equ constants from a symbol harvest by parsing the SOURCE, not by listing names

- **axis:** `memory_tier` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-11

## Decision

A staging pipeline's symbol harvest classified anything numerically inside the staged-image address range as a staged label. Three separate hand-written constants (two scratch-buffer addresses, then a packed note value with no address meaning at all) hit this by pure coincidence of VALUE across two sessions, each fixed with one more name added to an exclusion list. The list was never going to hold -- every new equ constant was another chance to collide. Parsing the source file for every name equ line and excluding all of them generically closed the whole class in one fix.

## Precondition

A build step classifies symbols or objects by which numeric range they fall into, and the set of things that could coincidentally fall in that range keeps growing as the project grows. Prefer classifying by where a name is DEFINED (parseable from source) over classifying by what VALUE it happens to have.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
