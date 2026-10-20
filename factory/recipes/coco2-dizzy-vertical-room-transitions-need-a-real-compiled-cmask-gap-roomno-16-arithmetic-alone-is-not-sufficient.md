# coco2/dizzy: vertical room transitions need a real compiled-cmask gap, roomno+/-16 arithmetic alone is not sufficient

- **axis:** `memory_tier` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-02

## Decision

X-ALL.TXT's goneup/gonedown are unconditional roomno+/-16, so that arithmetic always names a real, valid room number -- but checktopside/checkbottomside (the ONLY things that call goneup/gonedown) require checkline to report a CLEAR probe first. If the target room's own wall/floor has no actual gap in the compiled collision mask, the transition can never fire in the original either, regardless of what the room-number math computes. Tried room 35->51 and room 52->68 on this basis and both are dead ends (room 35's y=48 wall is 100% solid, room 68's floor is 100% solid) -- found by decoding the real compiled cmask bytes, not by guessing from the arithmetic.

## Precondition

Any Dizzy-family (or similarly structured 2D platformer) port where room adjacency is computed arithmetically from a room index, and a NEW vertical (or any collision-gated) transition is being added rather than reproducing one already proven in the source.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
