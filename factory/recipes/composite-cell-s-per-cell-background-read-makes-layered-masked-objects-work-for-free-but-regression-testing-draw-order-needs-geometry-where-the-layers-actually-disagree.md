# composite_cell's per-cell background read makes layered masked objects work for free, but regression-testing draw order needs geometry where the layers actually disagree

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-28

## Decision

T0051 draws two masked objects (a rock archway, then a vault door) onto overlapping screen cells with zero new engine code -- composite_cell always reads whatever character code is CURRENTLY in screen memory as its background, so drawing object B after object A automatically composites B onto A's result in any shared cell. This is a free consequence of T0048's design, not something T0051 had to build. However, a draw-order regression test (swapping which object draws first) produced NO visible diff here (0.0153%, pure jitter) because the one cell where the two shapes overlap happened to have mask/data bytes that agree regardless of order -- both objects wanted the same bits off there, by construction (the archway's opening was sized to match the door's shape). A wrong-bank regression (the same class used throughout this file family) still caught real breakage reliably (1.8861%, 37x threshold).

## Precondition

Applies to any future scene assembled by layering multiple masked objects via composite_cell on this engine. Before trusting a draw-order regression test as proof the layering mechanism works, confirm the overlapping cells' mask/data actually differ between the two draw orders for at least one bit -- aligned/complementary geometry (like T0051's door-shaped archway opening) can make a real ordering bug produce zero visible difference. A cleaner regression for this class: pick two objects whose overlap region has genuinely conflicting content, not shapes designed to fit together.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
