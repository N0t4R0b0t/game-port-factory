# Judge dither/art work on the raw framebuffer capture, not a composite-simulating emulator screenshot, when the target hardware has an S-Video or RGB mod

- **axis:** `raster` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-30

## Decision

xroar and MAME both faithfully simulate NTSC composite artifact colour, which makes fine dither patterns fringe into rainbow. A machine with an S-Video mod bypasses that path entirely and shows crisp black/white. Judging art on the composite-simulated screenshot is therefore pessimistic and drives a wrong decision -- on dizzy-coco2 it had already produced a deferred 'use coarser dither to reduce fringing' art decision that turned out to be void once the user confirmed their CoCo2 is S-Video modded. Capture the framebuffer bytes and render them monochrome instead.

## Precondition

The real target hardware the user plays on has an S-Video, RGB, or other non-composite video path; and the emulator in use simulates composite artifact colour. Ask -- this is a property of the user's specific machine, not of the platform, and cannot be inferred from the platform id.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
