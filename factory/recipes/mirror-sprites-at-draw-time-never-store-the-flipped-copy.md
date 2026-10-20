# Mirror sprites at draw time; never store the flipped copy

- **axis:** `memory_tier` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-15

## Decision

A mirrored bitmap shares no byte runs with its source, so an LZ/RLE packer cannot collapse the pair -- the copy costs nearly full price, unlike ordinary duplicate art. In dizzy-coco2 that was 37 blobs / 1692 raw bytes, and removing them took the binary from 31638 to 30869 and load-time hole space from 130 to 868 bytes. If every sprite width is a multiple of 8, the flip is just 'reverse the byte order, reverse the bits per byte'; one 16-byte nibble table plus four shifts does the bit reversal without a 256-byte table. Carry the flag for free in a spare low bit of the placement's x when coordinates are 4px-aligned, rather than spending a byte per placement.

## Precondition

Sprite widths are a multiple of the byte width (else the flip needs a bit-shift fixup), placement coordinates have a spare low bit, and the flipped sprite is drawn rarely enough that the per-row reversal cost is affordable -- static scenery blitted once per room load always is; an actor redrawn every frame needs measuring first.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
