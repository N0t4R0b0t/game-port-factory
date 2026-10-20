# Give every independently-moving actor its own prior-position tracking, not just the player

- **axis:** `raster` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-01

## Decision

A shared 'clear then blit' helper that only clears the CURRENT draw spot is correct for anything static, but an actor that moves under its own power (an NPC patrol, not player-driven) leaves every previous frame's footprint un-erased -- OR-compositing only adds ink, never removes it. This produced a visible dot-trail and a leftover mirrored-sprite artifact on direction changes, only found via real interactive playtest, not by reading the code (the bug is invisible in a single static frame).

## Precondition

An actor updates its own position without going through the same per-frame damage-rect machinery the player character uses. Does NOT hold for actors that only move by being pushed/placed by other game logic on the same cadence as the player redraw already tracks.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
