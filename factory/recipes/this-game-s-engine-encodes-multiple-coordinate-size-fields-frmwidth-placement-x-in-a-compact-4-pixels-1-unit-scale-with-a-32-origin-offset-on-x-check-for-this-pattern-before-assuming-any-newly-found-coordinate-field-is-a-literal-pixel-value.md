# This game's engine encodes multiple coordinate/size fields (frmwidth, placement x) in a compact '4 pixels = 1 unit' scale with a +32 origin offset on x -- check for this pattern before assuming any newly-found coordinate field is a literal pixel value

- **axis:** `raster` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-29

## Decision

Confirmed for frmwidth (T0009/T0012, via source comment) and independently for room-placement x (T0014, via reading frame's actual blit-position code: frmxcoord-32 then >>1). Two independent fields share the identical compact-unit convention, suggesting other yet-unread coordinate fields in this codebase (Dizzy's own on-screen x, proximity-trigger box coordinates, etc) may use the same or a related convention rather than literal screen pixels -- worth checking explicitly rather than assuming direct pixel units by default.

## Precondition

decoding any new coordinate, width, or size field from this specific Fantasy World Dizzy source tree

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
