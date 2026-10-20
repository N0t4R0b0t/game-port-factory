# Lay out scratch buffers by lifetime, and let buffers that are never alive together share space

- **axis:** `memory_tier` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-12

## Decision

dizzy-coco2 kept the title's gather buffer, unpacked image, room mask and title-music player in separate areas (~13.9KB) and ran out of room-image headroom; sharing one transient 6144-byte area between the unpacked title, the music player and the room mask (never alive at once), and keeping the packed stream instead of the unpacked image, cut it to ~11.6KB with zero code bytes

## Precondition

several boot/transient buffers sit in one address space and their liveness windows can be shown not to overlap

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
