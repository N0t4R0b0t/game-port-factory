# When a coordinate/mockup 'looks plausible but off' during reverse-engineering, check the pattern quantitatively before accepting a plausible-sounding explanation

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-29

## Decision

A room-22 mockup rendered with the raw x-coordinate byte looked like a coherent-ish (if odd) room layout -- confined to a narrow band, objects piled up -- easy to shrug off as 'this game's room layouts are just unusual'. Actually checking the numbers (all 78 placements fell 100% inside a specific, narrow, otherwise-unrelated message-box window rectangle -- not approximately, exactly) revealed the real bug: x is encoded in the same compact 4-pixels-per-unit scale used elsewhere in this codebase (frmwidth), not a literal pixel coordinate. The fix (real pixel_x = (x-32)*4) produced an obviously-correct, full-width room scene. The suspicious-coincidence pattern was only caught by computing containment counts, not by eyeballing the image.

## Precondition

a decoded/rendered mockup during reverse-engineering looks off in a way that has a plausible in-universe explanation (unusual game design, odd art style, etc) -- check whether the data quantitatively matches some OTHER known boundary/constant in the source (a window, a table size, a register range) before accepting the plausible story; an exact or suspiciously-clean match to an unrelated constant is a strong signal of a units/scaling bug, not a coincidence

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
