# Clip sprite blits to the framebuffer even when no sprite should need it

- **axis:** `raster` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-04

## Decision

A blit that walks rows without a bound writes into whatever follows the framebuffer the moment any placement sits closer to the bottom edge than its own height -- and the game's own data will contain one. It stays invisible for as long as the bytes behind the buffer are harmless (a sprite bitmap), then turns fatal when a layout change puts a pointer or a sprite header there: the next blit through that header runs away through the I/O registers. The clip is four instructions on a path that already loads the height.

## Precondition

A blit that computes its destination by walking rows, with anything at all mapped after the framebuffer

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
