# When a coordinate needs a unit transform, its WIDTH needs the same one -- and a too-narrow hitbox reads as a sequence bug, not a size bug

- **axis:** `raster` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-03

## Decision

Fantasy World Dizzy stores x in 4-pixel units and y in pixels, so a ported proximity box needs *4 on x AND on w, but nothing on y or h. This port transformed x alone for two years of sessions, leaving every trigger box a quarter of its real width. What that looks like in play is the important part: nobody reports "the hitbox is too small", they report "there seems to be a mandatory sequence of events" or "it only works sometimes", because a box narrower than the movement stride has only one or two valid standing positions and finding one feels like having satisfied some hidden prerequisite. An earlier session had even hand-widened two of the boxes to compensate, treating the symptom, which then masked the shared root cause. Confirm the unit by finding what the original uses as the PLAYER width in the same comparison (here eggwidth=6 for a 24px sprite); if that constant is not the sprite width in pixels, the whole comparison is in scaled units.

## Precondition

Porting collision/trigger rectangles out of an original whose coordinates are not in pixels. Check the comparison routine for a hardcoded player width/height constant -- it tells you the unit of everything else in that comparison, including the box extents.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
