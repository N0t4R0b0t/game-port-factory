# Stage high-memory data through a framebuffer, not low RAM

- **axis:** `memory_tier` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-03

## Decision

A relocate-at-boot staging area only needs RAM the loader can write that nothing touches before the copy runs. A framebuffer is exactly that and is usually the largest such block on an 8-bit target: on the CoCo2 it is 6KB against the 228 bytes left in low RAM, and the copy loop needs no change if it is written label-relative. Freed three regions at once and took the code region from 6 bytes of headroom to 1.5KB.

## Precondition

The target loads via a loader that cannot write the destination region directly; the relocate runs before anything draws into that buffer; the staged image fits inside it

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
