# Compress the load file, never the runtime data structures

- **axis:** `memory_tier` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-26

## Decision

Measured on dizzy-coco2: the collision mask costs 0 resident bytes (overlaid on the transient title buffer, sized by the music mixer), cropping it saves 0 for the same reason, the map is already a 3-byte-per-placement vector format beating the equivalent bitmap 8x, and three random-access sprite-compression schemes all lost (0 duplicate sprites after roompack's own dedupe, 32 bytes of blank rows, and a row pool came out 739 bytes WORSE than the 3988 it replaced). What DID pay was LZ-packing blobs that ship RAW in the load file and unpacking once at boot: Dizzy's frames 4806->1976, because each frame carries a mask of $ff/$00 runs. Delivery budget, not RAM, was the binding constraint all along.

## Precondition

Check WHERE a buffer lives (its equ chain and the map), not just how big it is: a buffer overlaid on transient RAM that something else already sizes is free to shrink and frees nothing. Compression pays only on a blob that ships raw in the load file, is read per-frame so it cannot be compressed in place, and whose saving exceeds the ~10-20 bytes its own unpack call costs. Resolve fdb symbol operands before trusting any ratio -- writing them as zeros fabricated two wins.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
