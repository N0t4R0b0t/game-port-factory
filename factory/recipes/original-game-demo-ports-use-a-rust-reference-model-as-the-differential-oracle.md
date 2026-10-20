# Original-game demo ports use a Rust reference model as the differential oracle

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-10-17

## Decision

With no original binary to diff against, a bit-exact integer-only model plus a fixed RAM state block (gpf_state) lets any target be verified by polling RAM against golden traces; no screenshots needed

## Precondition

Game is an original design with deterministic integer-only rules and a 50Hz fixed-step simulation; fails if rules need RNG or floating point

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
