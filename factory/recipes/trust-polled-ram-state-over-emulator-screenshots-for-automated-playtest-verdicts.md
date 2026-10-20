# Trust polled RAM state over emulator screenshots for automated playtest verdicts

- **axis:** `raster` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-31

## Decision

CoCo2 PMODE4's NTSC artifact-color rendering turns every sprite into a speckled dot pattern that is hard to tell apart from background or from other sprites even blown up 4x in a saved screenshot. A scripted playtest that judged success by eyeballing captured frames would have been unable to tell 'Dizzy is standing here' from 'Dizzy is not drawn' with any confidence. Reading the game's own state variables (position, room, lives, flags) straight out of emulated RAM via the build's own symbol map is unambiguous and cheap, and doesn't depend on interpreting a hard-to-parse palette.

## Precondition

The target's video output is genuinely hard to parse from a still image (composite/NTSC artifact color, low resolution, heavy dithering) AND the thing being checked has a corresponding state variable in RAM. Does NOT hold for a target with clean high-contrast graphics (this project's own ZX Spectrum reference captures ARE safe to eyeball directly), or for checking something with no RAM representation (does the tumble ANIMATION look right, not just does the position change) -- that still needs a human or a vision model looking at the actual pixels.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
