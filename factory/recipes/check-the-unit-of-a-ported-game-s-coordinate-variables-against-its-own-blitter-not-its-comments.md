# Check the UNIT of a ported game's coordinate variables against its own blitter, not its comments

- **axis:** `raster` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-03

## Decision

Fantasy World Dizzy stores Dizzy's x in FOUR-PIXEL units (PRTDIZZY.PDS makes x/2 the screen byte column) while storing y in plain pixels, and room placements use a THIRD convention (4px units biased by +32). The sprite routine's own header comment claims 'e=x (0=left 255=right)', which is stale and wrong. Trusting it silently mis-scaled every derived constant taken from the source -- spawn point, screen-edge transition triggers, room arrival positions -- by 4x, and made the correct movement speed look like an unfaithful 'modern feel' choice for years of sessions. The blitter's address arithmetic is the ground truth: whatever the code divides x by to reach a byte column tells you the unit. Cross-check with values that only make sense in one reading (edge bounds like 'x==1' and 'x==57' are absurd as pixels, exact as units) and against a real capture of the original.

## Precondition

Any port that lifts numeric constants (spawn points, bounds, arrival positions, step sizes) out of an original's source. Applies with extra force when different entity types in the same game use different coordinate conventions, which is common in 8-bit games that pack x into a byte-column plus a sub-byte shift.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
