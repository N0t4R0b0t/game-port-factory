# ACME's !scr pseudo-op maps uppercase source letters to the shifted/graphics charset, not plain letters

- **axis:** `color` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-22

## Decision

T0042's map tiles used ACME's !scr directive to emit raw C64 screen codes (needed for direct screen-RAM writes, unlike !text which emits PETSCII for CHROUT). An uppercase 'D' written via !scr did not render as the letter D on screen -- it mapped to a shifted/graphics character instead, because !scr's screen-code mapping differs from !text's PETSCII mapping specifically in how it treats uppercase source letters. Fixed by writing the door tile as lowercase 'd' in source, which correctly produces the uppercase D glyph on screen (screen-code charset conventions invert case relative to what a human typing PETSCII text expects).

## Precondition

Any future ASM source using ACME's !scr (or any raw-screen-code emission, as opposed to !text/CHROUT-bound PETSCII) to place a letter character as a map tile, UI glyph, or similar must verify the rendered output against a real VICE screenshot before trusting the source-level case -- the same empirical-verification discipline already established for PETSCII byte values (see the petsci-byte-value decision) applies here too, just for a different charset-mapping trap.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
