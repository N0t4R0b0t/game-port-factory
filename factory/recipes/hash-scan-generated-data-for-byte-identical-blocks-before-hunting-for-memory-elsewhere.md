# Hash-scan generated data for byte-identical blocks before hunting for memory elsewhere

- **axis:** `memory_tier` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-12

## Decision

a 40-line scan of the generated room .asm found 4.2KB of identical tiles (per-room flame/water sets, self-contained rooms re-emitting shared tiles); deduplicating them freed 4.2KB raw / 1.5KB packed, more than any code change could

## Precondition

a converter emits per-unit data files that are concatenated into one image, and some art is shared across units

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
