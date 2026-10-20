# xroar '-machine coco2bus' is the real NTSC Tandy CoCo 2; 'coco2b' is the PAL variant

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-28

## Decision

Easy to pick wrong from 'xroar -machine help' since coco2b sorts before coco2bus and 'looks' like the plain answer. Using the PAL machine for what's meant to represent a real US-market Tandy CoCo 2 would give the wrong timing/video-standard baseline for any timing-sensitive work later.

## Precondition

targeting a real US/NTSC Tandy CoCo 2 in xroar (not a PAL Dragon/CoCo market)

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
