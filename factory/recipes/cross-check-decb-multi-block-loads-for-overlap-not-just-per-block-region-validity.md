# Cross-check DECB/multi-block loads for overlap, not just per-block region validity

- **axis:** `memory_tier` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-05

## Decision

A block can individually pass a fixed-region audit and still silently overwrite an EARLIER-loading block at the same physical addresses -- CLOADM (and similar sequential loaders) apply blocks in file order, later wins. This shipped unnoticed for a whole task (dizzy-coco2 T0074) because memaudit.py only checked each block against a static region list, never blocks against each other. Two staging windows sharing a hard byte budget (e.g. two 6KB SAM-banked regions) is exactly the shape that triggers this; the bug hid until a LATER, unrelated change (T0075) shifted which bytes got corrupted onto something load-bearing.

## Precondition

Target has 2+ regions populated by SEPARATE generator invocations/includes that are each staged then relocated, especially when one region's size is data-driven (grows with room/asset count) rather than fixed. Also applies whenever a shared/deduplicated resource pool needs to be split across more than one such region under a budget.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
