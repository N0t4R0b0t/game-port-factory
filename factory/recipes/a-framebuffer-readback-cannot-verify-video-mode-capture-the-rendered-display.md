# A framebuffer readback cannot verify video mode -- capture the rendered display

- **axis:** `raster` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-02

## Decision

Decoding a framebuffer dump back into an image assumes the display mode you are trying to verify, so it renders a perfect picture even when the hardware is showing something else entirely. On dizzy-coco2 a wrong PIA1 mode nibble put the machine in CG6 (128x192, 4 colour) instead of PMODE4 (256x192, 1bpp) for days: half the horizontal resolution silently discarded, all art turned to colour mush, while the headless framebuffer harness stayed green and the user's contradicting screenshot was written off as an environment issue. Diagnose an unknown display by filling the framebuffer with known byte-pattern bands and photographing the RENDERED output -- the pattern-to-colour mapping identifies the mode unambiguously.

## Precondition

Any target where the framebuffer is interpreted by a display chip with selectable modes (VDG, VIC, TED, ULA...) -- i.e. where the same bytes can legally mean different pictures. Not needed where the framebuffer format is fixed by hardware.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
