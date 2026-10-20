# For a Spectrum ink/paper source with detailed small-sprite pixel art ported to CoCo2, prefer flat PMODE4 (6R, 256x192, 2-color) over semigraphics or artifact-color tricks

- **axis:** `color` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-29

## Decision

Rendered a real comparison: PMODE4 keeps full 256x192 sharpness (matches the source art's native pixel-exact extraction with zero rework); simulating SG4 (semigraphics, 4x6-pixel chunky blocks) on an actual 24x21 Dizzy sprite destroyed nearly all recognizable detail down to two blobs; simulating 6C (128x192, real 4-color, half horizontal resolution) was visibly softer but still recognizable. NTSC artifact color was ruled out earlier for the same reason plus its composite-only/boot-random-color caveats. User's explicit priority was not compromising art sharpness, which the rendered comparison made concrete rather than theoretical.

## Precondition

porting detailed small-scale pixel-art character/object sprites (not large flat color washes) from a source platform with per-cell/per-pixel color to the CoCo1/2's MC6847 VDG -- re-evaluate if the source art is coarser/larger or if a specific flat-color background element would benefit from CSS or artifact-color treatment instead

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
