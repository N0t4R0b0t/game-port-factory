# Name expected deviations with a reason; EXPECTED is a visible verdict, never silently swallowed, and unused entries warn as STALE

- **axis:** `color` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-10-20

## Decision

Platform differences (monochrome vs attribute colour, 50 vs 60 Hz) are not port bugs but must stay visible; a silent allowlist hides regressions and goes stale

## Precondition

There is a known, explainable difference between source and target that no port change should close; fails when the 'deviation' is really an unfixed bug, which belongs in a task not in expectations.toml

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
