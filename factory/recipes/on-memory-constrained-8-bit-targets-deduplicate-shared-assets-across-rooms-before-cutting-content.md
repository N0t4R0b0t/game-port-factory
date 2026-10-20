# On memory-constrained 8-bit targets, deduplicate shared assets across rooms before cutting content

- **axis:** `memory_tier` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-02

## Decision

A multi-room build on a tight 8-bit memory budget will often duplicate identical assets (wall tiles, doors) across rooms under room-prefixed labels, especially once per-room shading/variants are turned off and every placement of a frame collapses to one identical variant. That duplication is pure waste, discoverable by comparing generated output across rooms, and fixing it is zero-cost to fidelity -- strictly better than trimming room content, which was the first instinct. dizzy-coco2 recovered ~570+ bytes this way and it was enough to fit a new room without cutting anything. Check for cross-room asset duplication BEFORE proposing a content cut on a tight target.

## Precondition

Target has multiple rooms/levels sharing a common tileset, and the current pipeline emits each room's assets independently (no existing shared-asset table). Requires a build/assembler that has no automatic dedup of identical data (true of hand-assembled 6809/Z80 asm).

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
