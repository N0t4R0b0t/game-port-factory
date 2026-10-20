# A guard that can fire on a good build is worse than no guard

- **axis:** `storage` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-06

## Decision

The first version of this overflow guard used lwasm's "if a > b", which is not a comparison -- lwasm's plain "if" is only "expression is non-zero", so "if 1 > 2" is TRUE and the guard fired on every build including correct ones. A check that cries wolf gets deleted rather than believed. Prove a guard stays silent on a known-good input before trusting it to catch a bad one. (lwasm has "ifgt <expr>", a real signed test against zero, for this.)

## Precondition

Adding any build-time assertion. Verify BOTH directions: it fires on the bad input and stays silent on the good one.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
