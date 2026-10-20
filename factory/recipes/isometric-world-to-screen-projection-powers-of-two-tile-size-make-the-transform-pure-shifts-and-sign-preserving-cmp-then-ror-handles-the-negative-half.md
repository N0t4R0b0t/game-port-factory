# Isometric world-to-screen projection: powers-of-two tile size make the transform pure shifts, and sign-preserving CMP-then-ROR handles the negative half

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-28

## Decision

T0049 implements screen_x=(tile_x-tile_y)*(tile_width/2), screen_y=(tile_x+tile_y)*(tile_height/2), then /8 to text row/col. Choosing tile_width=32/tile_height=16 (the classic 2:1 isometric diamond ratio) makes every multiply a left-shift (x4 and x3) instead of a real multiply routine. screen_x is signed (an object placed 'north' on the tile grid has tile_y>tile_x), so the /8 step needs a genuine sign-preserving shift, not a plain LSR: CMP #$80 puts bit 7 into carry without altering A, then ROR feeds that same bit back into bit 7 -- correct two's-complement division by 2, applied 3x for /8. A plain LSR would corrupt negative offsets. Verified by a deliberate regression (turning the tile_x-tile_y subtraction into addition) which visibly broke object placement and failed the check target at 0.1264%, 2.5x the threshold.

## Precondition

Applies whenever placing objects with an isometric world-to-screen transform in this project's text-mode/raster-band engine. Only holds while tile_width/tile_height stay powers of two -- an art-driven size change to a non-power-of-two would need a real multiply routine instead of shifts. Does not itself handle cross-band placement (an object whose computed row crosses LINE1/LINE2/LINE3) -- still unsolved, same as T0047/T0048's scope notes.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
