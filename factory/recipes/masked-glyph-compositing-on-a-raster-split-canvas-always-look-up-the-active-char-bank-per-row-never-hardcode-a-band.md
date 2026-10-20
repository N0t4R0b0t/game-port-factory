# Masked glyph compositing on a raster-split canvas: always look up the active char-bank per row, never hardcode a band

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-23

## Decision

For per-cell software-sprite masking on T0047's raster-split character-bank canvas, composite_cell must look up which bank is ACTUALLY active for a given text row (bank_for_row, driven by the same LINE1/LINE2/LINE3 constants the IRQ chain uses) before reading the background glyph and writing the composited one, never assume/hardcode a band even when the object currently only touches one. Verified by a deliberate regression: hardcoding the wrong bank produced a real failure (glyph codes land in the wrong bank's unwritten slots, rendering as a solid black hole), 13-15x the measurement-noise threshold.

## Precondition

Applies to any future object/tile placed on a raster-split character-bank canvas built with T0047/T0048's scaffold. Does NOT cover an object straddling a raster-split seam (glyph data would need splitting across two banks) -- still unsolved. Before reusing: confirm the target canvas still uses per-row bank switching (not a true bitmap mode) and that LINE1/LINE2/LINE3-style boundaries still define the active bank.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
