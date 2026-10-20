# Reduce a multi-channel chiptune by committing to ONE lead channel per tune, not by picking the loudest channel each frame

- **axis:** `audio` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-11

## Decision

Per-frame 'loudest' flips whenever two channels' volume envelopes cross, and the two loudest are usually bass and melody, so the output zigzags octaves apart every few frames -- unrecognisable, not merely imperfect. Scoring channels over the whole capture and picking the voice that MOVES (most distinct pitches, higher register breaking ties) picked the melody correctly on every dizzy-coco2 capture, including one where only a single channel sounds at all.

## Precondition

Reducing AY/PSG/SID-style multi-channel music to a single-voice output

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
