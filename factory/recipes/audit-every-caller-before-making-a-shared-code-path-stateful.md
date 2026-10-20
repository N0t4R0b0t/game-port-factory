# Audit every caller before making a shared code path stateful

- **axis:** `raster` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-01

## Decision

Added per-buffer last-position tracking to a routine so ONE caller (a moving actor) could clear its old position correctly. The routine was reached via a shared label that a DIFFERENT set of callers (every static actor whose box overlapped the damage rect) also fell through into unconditionally -- they started reading and overwriting the same tracking state meant for just the first caller, corrupting both. The fix that added state passed its own tests perfectly; the bug was entirely in not checking who ELSE could reach that label first.

## Precondition

Adding any per-call persistent state (a 'last X' variable, a cache, a counter) to a routine reached via a shared branch/fallthrough target, not a single dedicated call site. Before adding the state, enumerate every path that can reach the label -- 'it happens to land here too' is not the same as 'it needs this'.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
