# A software square-wave DAC's per-toggle cost is often dominated by a FIXED overhead, not the target pitch -- there is no such thing as a cheap low note

- **axis:** `audio` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-11

## Decision

Measured play_tone's real cost model (dizzy-coco2 T0089): ~21.1*period+1164 cycles per full wave, where +1164 does not shrink at low period. A single half-wave toggle of a ~68Hz click alone cost ~9ms -- more than an already-tight 66.7ms frame budget could absorb even once. Unlike real AY/PSG hardware (a free-running counter per channel regardless of pitch), a delay-loop DAC needs either a high pitch or a hard per-note duration cap for anything meant to fire during active gameplay.

## Precondition

Porting AY/PSG or other hardware-channel music/sfx to a software delay-loop square-wave DAC

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
