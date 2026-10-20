# Keep a commercial game out of git by shipping tools + templates and hash-verifying user-supplied inputs

- **axis:** `storage` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-10-20

## Decision

Only code, text templates (keys into the user's source) and a hash list are public; a bootstrap regenerates every derived file locally into gitignored paths and verifies the result byte-for-byte against recorded artifact hashes

## Precondition

The build chain starts from files the user can obtain themselves and every derived file has a deterministic generator; fails if any build input is hand-edited and mixes original expression with port code (split it first: public templates + keys)

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
