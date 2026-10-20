# Measure the compressor against the real bytes before choosing one

- **axis:** `storage` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-06

## Decision

RLE is the reflexive choice for tile/sprite art and it INFLATED this data to 145% -- 40%-ink dithered 1bpp has almost no byte runs. LZSS on the same bytes was 64%. The measurement took minutes and the wrong choice would have been a wasted subsystem plus a target-side decoder.

## Precondition

Any port where staged or resident data must be compressed. Run each candidate over the actual extracted bytes, not a sample and not intuition.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
