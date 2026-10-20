# Derive room collision solidity from the original's own colour/attribute-byte rule, rasterized from real sprite pixels, not a hand-authored per-room solid list

- **axis:** `color` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-30

## Decision

Fantasy World Dizzy's own engine already encodes walkable-vs-decorative per placement via a colour attribute byte (bit 6 = BRIGHT = non-solid, checkattri's 'bit 6,a / ret nz'), verified against real room-36 data (brickwork bit6=0, torches/decorations bit6=1) before trusting it. Rasterizing each solid placement's ACTUAL decoded sprite pixels into a coarse block grid (not just its bounding box) correctly leaves gaps under arches/tables walkable for free, matching the original's pixel-scan-based collision without needing CoCo2's nonexistent attribute plane.

## Precondition

Source data carries a per-placement colour/attribute byte that the original engine itself already uses to gate collision or a similar boolean property (not just visual color); target platform has enough RAM for a coarse (multi-pixel-per-block) collision mask alongside the real framebuffer(s).

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
