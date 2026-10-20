# Damage-rect partial redraw for real-time responsiveness on 6809/SAM, not full-screen every frame

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-29

## Decision

CoCo2's SAM inserts RAM wait-states during graphics-mode video generation, so a full 6144-byte clear + all-placements blit is genuinely slow at real CPU speed -- double buffering fixes the FLICKER from this but not the sluggishness, since the same total work still happens every frame. Tracking each sprite's own last-drawn position (per off-screen buffer, since buffers alternate) and only clearing+re-blitting the small region that actually changed -- via a cheap AABB overlap test against each placement's own header width/height -- cuts the real per-frame cost from all 63 placements to typically 0-2. Verified correct with a differential test (poke position, synthetic JSR into redraw, byte-diff against an independently-built full-redraw reference) before trusting the hand-derived overlap math.

## Precondition

Any CoCo1/CoCo2 (or other 6809-class target with slow video-mode RAM access) scene with a mostly-static background and a small number of moving sprites; less valuable if most of the screen changes every frame anyway.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
