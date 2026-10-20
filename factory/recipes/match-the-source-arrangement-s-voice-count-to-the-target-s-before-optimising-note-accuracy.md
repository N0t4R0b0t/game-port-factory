# Match the SOURCE arrangement's voice count to the TARGET's, before optimising note accuracy

- **axis:** `audio` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-11

## Decision

dizzy-coco2 reduced a 3-channel AY title tune to the CoCo2's single blocking DAC and got every note within 0.06 semitones of the original -- and the playtest still rejected it, because accuracy on one voice cannot replace the harmony and bass that were discarded. The same game's 48K release had a beeper arrangement composed for one channel; captured and shipped, it sounds like the tune. When a target is monophonic, prefer a monophonic-era source arrangement over a faithful reduction of a polyphonic one.

## Precondition

The source game shipped more than one audio arrangement (e.g. 48K beeper and 128K AY) and the target has fewer voices than the richer one

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
