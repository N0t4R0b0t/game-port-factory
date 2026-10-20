# Verify a recording against a simulation of the data that produced it

- **axis:** `audio` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-12

## Decision

Spectral and dominant-pitch metrics on a 3-square-wave mix scored a misaligned control as high as the true alignment, and a stale reference WAV looked like a regression; a Python decode of the actual stream gave NCC 0.67-0.92 and exposed a 1.6% tempo drift

## Precondition

the target plays deterministic data (event stream / note table) whose decoder is simple enough to re-implement offline

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
