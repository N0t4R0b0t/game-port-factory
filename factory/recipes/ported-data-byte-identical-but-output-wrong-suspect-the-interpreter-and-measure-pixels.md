# Ported data byte-identical but output wrong: suspect the interpreter, and measure pixels

- **axis:** `raster` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-02

## Decision

When a port copies the original's data verbatim and the result still looks wrong, the fault is in the code reading that data, not the data or the art. dizzy-coco2 hit this twice in one session: message boxes drawn W+2 glyphs wide instead of the original's W+4 and one glyph row too high, which pushed correctly-positioned text off centre. Both were found by measuring the framebuffer (text ink centre vs box centre) rather than eyeballing a screenshot -- the eyeball reading was 'shifted left' when the truth was 8px right and 8px down. Screenshots at emulator scale, especially with NTSC artifacting, are not reliable for pixel-level claims.

## Precondition

The port reuses the original's data files or byte streams unmodified, so any discrepancy must come from the consuming code. Requires a way to read the target's framebuffer -- if you can only see a scaled/filtered screenshot, build that readout first.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
