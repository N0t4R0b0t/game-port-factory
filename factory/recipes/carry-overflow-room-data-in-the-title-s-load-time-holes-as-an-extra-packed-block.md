# Carry overflow room data in the title's load-time holes as an extra packed block

- **axis:** `memory_tier` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-14

## Decision

dizzy-coco2 T0125: rooms 39+23 put the framebuffer staging windows 255 bytes short in total, while the scattered load-time holes the title already rides had ~1KB spare. Appending a third packed block to the title's gathered stream (mktitle --extra, explicit offset, round-trip check) and unpacking it at new_game from the permanent gather buffer cost ~10 bytes of resident code and no format change. Watch the fragment-table size (fixed at 6 entries) and the scratch chain above the image, which grows by the block's raw size plus its packed size.

## Precondition

boot already gathers packed data from load-time holes into a buffer that stays alive for the whole game, and the unpacked image has room to grow past its current end

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
