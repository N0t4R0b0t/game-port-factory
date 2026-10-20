# A behavioural-diff harness must be proven deterministic before its diffs are believed

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-06

## Decision

sweep.lua's clamped start points deduplicated to the same room-edge position, where holding a direction transitions immediately. Those trials disagreed with each other WITHIN one run, so the build-to-build diff showed three differences that were pure noise. Running the same binary twice and requiring byte-identical output is what separates signal from noise.

## Precondition

Any harness whose output is consumed as a diff between two builds. Establish run-to-run determinism first; a non-deterministic trial is worse than no trial, because it manufactures regressions.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
