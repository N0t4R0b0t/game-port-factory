# On banked-ROM targets, check what the video hardware can actually address

- **axis:** `raster` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-12

## Decision

Banking makes total content look unconstrained, but the display hardware often cannot read the banked medium. On C64 the VIC-II sees only RAM plus character ROM, never cartridge ROM at 0x8000-0xBFFF, so all graphics must be copied cart->RAM into the current 16KB VIC bank before display. The art budget is therefore set by the video window, not by cart size — a factor-of-64 difference on a 1MB cart. Code is the opposite: it executes from cart at zero RAM cost.

## Precondition

Target has banked/paged ROM AND a display processor with its own address view. Check whether the video hardware can read the banked medium directly; on systems where it can (many cartridge consoles map ROM into PPU/VDP space) this does not apply.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
