# A whole-frame pixel-diff threshold sized to catch object-level bugs will not reliably catch single-cell art data errors

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-28

## Decision

T0050's isovault-check uses the same --threshold 0.0005 (0.05% of the whole 384x272 captured frame) as T0047-T0049. A deliberate regression corrupting one 8-byte data table out of a 16-cell hand-authored object produced only a 0.0364% diff -- below that threshold, so the check would NOT have failed. The denominator is the whole frame (mostly static border), not the object's own footprint, so a bug confined to one cell of a multi-cell object gets diluted below a threshold that was originally sized against object-level regressions (wrong bank, wrong position) which move hundreds of pixels. A same-magnitude wrong-bank regression on this file still failed clearly (0.5687%, 11x threshold) -- the check target is not broken, it just has an uneven blind spot by bug class.

## Precondition

Applies to any future hand-authored multi-cell art asset verified by a whole-frame harness diff on this raster-band engine. Before trusting a green check as proof every byte of art data is correct, know that single-cell-level corruption may not be reliably caught at this threshold; the safeguard for that class of error is the generation process itself (a script, not freehand transcription) plus visual inspection, not the check target. If this needs closing properly: diff just the object's own pixel region instead of the whole frame, or generate the byte tables at build time from source data instead of hand-transcribing them so there's nothing to transcribe wrong.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
