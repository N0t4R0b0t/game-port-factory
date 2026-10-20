# A per-room flag in this engine can gate a DIFFERENT room's placement list being drawn as an overlay, not a flag on a local object in the current room

- **axis:** `raster` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-31

## Decision

Fantasy World Dizzy's fire-out mechanic (proxjugrou sets a global fireout flag) is implemented by checkfireout, called every time room 36 is redrawn: while unset, room 36 draws an ENTIRELY SEPARATE room's (room 2) whole placement list as an extra pass on top of itself. Room 2 turns out to contain nothing but 4 flame placements forming a fire pit -- a real, freestanding piece of content, not a property of an object already in room 36. A first attempt at this feature assumed the flag must gate one of room 36's own existing flame placements (the nearest one, by position) since that was the simplest reading of 'the water puts out the fire' -- wrong, and a real playtest immediately caught it as content that was simply missing rather than misbehaving. The tell that should have prompted checking the source sooner: the flag name itself (fireout) had no natural connection to any specific existing object index once actually implemented that way.

## Precondition

A CGA/Spectrum-era game engine where 'draw a room' is a generic routine over a data-driven placement list (not hardcoded per-room draw code), and a boolean/global flag appears to gate some visual change without an obvious local target. Check whether the flag's handler temporarily redraws a DIFFERENT room number's data as an overlay before assuming it must reference something already present in the current room.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
