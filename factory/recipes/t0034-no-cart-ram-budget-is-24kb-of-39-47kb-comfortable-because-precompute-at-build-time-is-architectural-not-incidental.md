# T0034: no-cart RAM budget is ~24KB of ~39-47KB — comfortable, because precompute-at-build-time is architectural, not incidental

- **axis:** `storage` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-22

## Decision

T0018 removed the assumption that engine code executes free from cart ROM, so code now needs a real RAM budget line item that never existed before. Built one bottom-up: ~7.4KB code (mostly estimated, unbuilt subsystems) + ~16.5KB data (unchanged from before, was never cart-dependent) = ~24KB total. The ceiling is not 64KB: $0801-$9FFF gives 38911 bytes with zero bank-switching (the same range BASIC's own free-memory figure comes from), and banking BASIC ROM out (KERNAL+I/O stay mapped, LOAD/SAVE/CHROUT keep working) adds $A000-$BFFF for 47103 total. The favourable finding: T0028's word-wrap already runs entirely at build time in Rust (to_c64_text), so the C64 does zero text-layout work at runtime -- that pattern, extended to item/critter/dialogue data as pre-converted binary tables rather than runtime format parsing, is why the budget has room a from-scratch on-device interpreter wouldn't.

## Precondition

Any future subsystem design should default to build-time precomputation (a datx recipe step) over on-device parsing/interpretation, matching the text pipeline's proof of the pattern. The two largest code estimates (SPECIAL/combat resolver ~2KB, dialogue state machine ~1KB) are unbuilt and the least certain numbers in this budget -- build those next to convert estimate into measurement; even a 2-3x overrun on both still fits within the ~14-22KB of headroom this budget computed. If a future subsystem's design genuinely can't be precomputed (true runtime logic — combat, movement, save state), size it explicitly rather than assuming it's free the way code used to be assumed free under the cart plan.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
