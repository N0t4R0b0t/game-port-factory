# Reproduce the source game's play WINDOW, not just its room data

- **axis:** `raster` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-05

## Decision

Extracted room/scenery data is authored against the original engine's own clipping. Fantasy World Dizzy defines windowtop=6*8 and windowbottom=192-8 and clips EVERY plotted sprite to y=48..184 (movestartdown: leading rows dropped and the source pointer walked forward by skipped*bytes_per_row; trailing rows truncated). dizzy-coco2 reproduced the placements faithfully but had no window, so room art that starts at y=48 BECAUSE 48 is the window top got drawn into a play area starting 24px higher -- a band of empty black above every ceiling, plus rooms whose art starts at y=32 spilling content the original simply cuts off. The player character needs the same clip and it is easy to miss: his draw path was a separate masked compositor that never went through the shared blit.

## Precondition

Source is an 8-bit game with a status bar or HUD above/below a smaller play area, and its room/scenery data contains placements outside the visible play region. Check for named window/clip constants in the disassembly BEFORE concluding the extracted coordinates are wrong or need re-deriving -- data running past the window is normal for something that expects to be clipped.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
