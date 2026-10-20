# Undo art workarounds once the display bug is fixed -- and verify verbatim, don't assume it

- **axis:** `raster` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-02

## Decision

Art transforms adopted to make a port 'look better' are often compensating for a rendering fault, not for a real limitation of the target. dizzy-coco2 accumulated three (tonal dither retuning, morphological closing, outline extraction) that all existed to work around a wrong video mode; once fixed, the correct pipeline was to change nothing, since source and target were both 256x192 1bpp. Re-derive the art from source after any display fix, and prove the result is untransformed with an independent decoder rather than trusting the flag list -- a checker that cannot fail proves nothing, so confirm it fails on a deliberately transformed build.

## Precondition

Source and target share a bitmap format (same resolution and depth), so a verbatim copy is meaningful. Where the target is genuinely lower-resolution or fewer-colour than the source, real art reduction IS needed and this does not apply.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
