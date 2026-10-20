# Directory-prefix filters over a DAT archive must also check file extension

- **axis:** `storage` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-22

## Decision

proto/critters/ contains critters.lst (a text index) alongside the real .pro binaries; a path-prefix-only filter fed it into the binary proto parser and overflowed an i32 summing garbage stat bytes — silent in release, a panic under cargo test's debug overflow checks. proto/items/ happened to be .pro-only so items.json was never at risk, but that was luck, not a property of the filter.

## Precondition

Any new datx feature that iterates entries by directory prefix (proto/*, art/*, text/*) — add an extension check, don't assume a directory only holds one file type.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
