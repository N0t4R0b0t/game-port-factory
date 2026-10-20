# To simulate tone on a 1-bit target, regularize already-dithered source art -- never thin it further

- **axis:** `color` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-30

## Decision

Art converted from an ink/paper platform (Spectrum, CPC) is typically ALREADY ~50% dithered, because on the source that dither shaded a COLOUR ('darker red'). In monochrome it is already pure noise, so multiplying it by a second luminance-derived dither produces visible damage -- broken walls, dissolved floors -- not dimness. Measured and captured on dizzy-coco2 room 36: thinning at duty 0.55 broke the wall band into disconnected chunks. The transform that works is the inverse: silhouette the sprite (border flood-fill, so interior texture gaps are distinguished from real transparency), preserve any pixel in a run of >=3 as drawn structure, and refill only the noise interiors with a clean ordered Bayer pattern at a luminance-derived duty. Texture becomes readable rather than dimmer.

## Precondition

Source art comes from a platform where colour was per-cell and artists used intra-cell dithering for shading (ZX Spectrum, CPC, MSX); target is 1bpp or otherwise cannot reproduce the source colour. Also requires per-placement colour metadata to derive luminance from -- without it there is no tone to map.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
