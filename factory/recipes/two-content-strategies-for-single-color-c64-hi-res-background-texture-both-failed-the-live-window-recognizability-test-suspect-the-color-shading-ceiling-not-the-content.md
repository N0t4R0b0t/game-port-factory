# Two content strategies for single-color C64 hi-res background texture both failed the live-window recognizability test -- suspect the color/shading ceiling, not the content

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-28

## Decision

T0052 tried two different content strategies for cave rock-wall texture on the raster-band engine: (1) four small per-cell noise variants scattered randomly, rejected live as 'speckled TV static, not stone'; (2) large hand-generated boulder silhouettes composited via the same masked-object technique as the door/archway, over a quiet low-density background tile, rejected live as 'I have no idea what this is supposed to be'. Both were mechanically sound (verified, regression-tested, read fine in cropped screenshots) but failed the same real test: a full, uncropped x64sc window shown to a real viewer. Two different content approaches failing the identical way suggests the ceiling may not be about WHAT shape the rock is, but that single-color (one foreground/one background color, no shading or depth) hi-res character mode cannot carry 'rock wall' as a recognizable concept at all, regardless of silhouette design.

## Precondition

Applies to any future background-texture attempt on this hi-res single-color raster-band engine. Before a third content-shape iteration, test the color hypothesis first: does C64 multicolor character mode (more colors per cell, real shading) change the outcome? This hypothesis was recorded but NOT tested before the user chose to deprioritize background art in favor of scene integration -- re-derive, don't assume, if background art work resumes.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
