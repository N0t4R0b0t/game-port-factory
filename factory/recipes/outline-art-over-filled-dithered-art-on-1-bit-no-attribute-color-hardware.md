# Outline art over filled/dithered art on 1-bit no-attribute-color hardware

- **axis:** `color` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-02

## Decision

Dithered/textured fills depend on a stable duty-cycle pattern rendering predictably, but 2-color hardware with only session-random NTSC artifact-color tricks (no genuine per-cell attribute color) can't guarantee that -- confirmed unresolved on both MAME and XRoar for CoCo2 PMODE4 this session despite correct CSS bit setup. A solid 1px outline with an empty interior is just solid ink on solid background in every render path, sidestepping the whole problem, and reads more legibly besides (confirmed via troll sprite: blob -> recognizable silhouette).

## Precondition

Target is 1-bit-or-few-fixed-color framebuffer hardware with no true per-pixel/per-cell attribute color (e.g. CoCo2 PMODE4, not ZX Spectrum's 8x8 attribute cells). Does not apply to targets with genuine solid-color fill support.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
