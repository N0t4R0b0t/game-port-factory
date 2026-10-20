# A repurposed movingdata field's meaning has to be re-derived per routine, never assumed shared

- **axis:** `memory_tier` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-01

## Decision

Two puzzle triggers (apple/troll, jug/fire) were both built checking 'is Dizzy carrying this item near a box', which seemed reasonable from the item's own proximity box existing in the data. The real source semantics were completely different: the trigger fires on the DROPPED item's own placed position, derived through a chain (dropobject places it, the caller re-checks proximity) that isn't visible from the box definition alone. Confirmed wrong twice by the user against the real game before being traced properly through the actual call chain.

## Precondition

A mechanic is inferred from a data structure's SHAPE (a box with x/y/w/h) rather than traced through the actual routine that consumes it. Re-derive the real trigger condition from the routine itself before implementing, even when a box/table's meaning seems self-evident from its fields.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
