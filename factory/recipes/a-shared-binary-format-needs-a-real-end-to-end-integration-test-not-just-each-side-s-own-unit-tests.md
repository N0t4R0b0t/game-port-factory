# A shared binary format needs a real end-to-end integration test, not just each side's own unit tests

- **axis:** `storage` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-22

## Decision

Split the dialogue graph work into a Rust extractor and an ASM interpreter, built in parallel against the same written spec, each with real passing unit tests (25 for the extractor, a working hand-authored-fixture demo for the interpreter). They were byte-incompatible: the extractor had an off-by-two address bug (double-counted the 2-byte load-address header that KERNAL LOAD actually consumes, never stores) invisible to all 25 of its own tests because those tests only checked the encoder's output against its own (consistently wrong) expectations -- never against a real emulator or the real interpreter. Found only by loading a real extracted Fallout dialogue graph through the real interpreter and hand-debugging the mismatch with a raw memory dump.

## Precondition

Whenever two independently-built pieces (by different sessions, agents, or people) must agree on a byte-level format they don't share code for, a real end-to-end run through the actual consumer (not a mock, not each side's own test fixtures) is required before considering the integration done -- regardless of how thoroughly either side is unit-tested in isolation. This generalizes the existing verifier-testing rule (test against a known-bad input) to a second axis: test against the REAL other half, not just plausible-looking self-consistent expectations.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
