# Cross-check any measured timing constant against the instruction cycle count before shipping it

- **axis:** `audio` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-11

## Decision

dizzy-coco2 T0089 re-derived a DAC pitch calibration with a measurement tool its own NOTES.md had already flagged as unreliable for pitch, and shipped music 6-40 semitones sharp. The loop was nine instructions: adding up the 6809 cycles gives 66+16*period per full wave, matches a good measurement to 1% across a 29x frequency range, and disagrees with the bad one by 32% on slope and 18x on intercept. The arithmetic is free and would have rejected the bad fit instantly.

## Precondition

Deriving a timing/pitch constant for a software-timed loop whose instruction sequence you can read

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
