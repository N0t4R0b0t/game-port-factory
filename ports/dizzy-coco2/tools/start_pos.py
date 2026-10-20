#!/usr/bin/env python3
"""Print a safe "X Y" spawn point for a room, for play.sh's room argument.

WHY NOT A FIXED POINT: the first version dropped Dizzy at x=128,y=80 in
every room. That is inside room 69's geometry, where the grounded
step-climb walks him up past TOP_TRANSITION_Y and straight out into room
85 -- you ask for 69 and arrive in 85. Any fixed point is inside a wall
in some room.

So read the room's real collision mask (the GENERATED one, same as
tools/roomview.py) and pick the widest walkable surface that is safely
below the transition line, then stand him in the middle of it. Falls
back to the middle of the screen if the room has no mask built, which is
the same thing the old fixed point did and no worse.
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))
# T0106: load_mask now decodes an LZSS-packed stream (room_cmask_lz), not
# a raw table -- reused from roomview.py rather than kept as a second
# copy. A second copy is exactly how this broke once already: T0106
# updated roomview.py's decoder and missed this file, and every room
# silently fell back to the "no mask" default (128,80) -- which happens
# to sit inside room 69's own geometry, so `./play.sh 53` started
# seeding room 53's items onto a build that actually opened in room 69.
from roomview import load_mask, CM_ROWS, CM_COLS, ROW_PX, COL_PX  # noqa: E402

# T0188: DERIVE the row height from the mask instead of hardcoding 4.
# The mask went to 1px rows (CM_ROWS 48 -> 192) and this file's `CELL = 4`
# silently multiplied every y by four: rooms 36 and 51 fell back to the
# "no mask" default (128,80), which in room 68 is inside the fireplace --
# reported as "dizzy spawns in the fireplace and dies right away".
# Exactly the second-copy failure this file's own header already warns
# about, one constant further along.
TOP_TRANSITION_Y = 66
BODY_W = 24          # Dizzy is 24px wide; he needs the surface to hold him


def surfaces(rows):
    out = []
    for r, row in enumerate(rows):
        above = rows[r - 1] if r else [False] * CM_COLS
        run = None
        for c in range(CM_COLS):
            top = row[c] and not above[c]
            if top and run is None:
                run = c
            elif not top and run is not None:
                out.append((r * ROW_PX, run * COL_PX, c * COL_PX))
                run = None
        if run is not None:
            out.append((r * ROW_PX, run * COL_PX, CM_COLS * COL_PX))
    return out


def main():
    room = int(sys.argv[1])
    rows = load_mask(room)
    if rows is None:
        print("128 80")
        return
    # Comfortably below the transition line, and wide enough to stand on.
    cands = [s for s in surfaces(rows)
             if s[0] > TOP_TRANSITION_Y + 24 and (s[2] - s[1]) >= BODY_W]
    if not cands:
        cands = [s for s in surfaces(rows) if s[0] > TOP_TRANSITION_Y + 24]
    if not cands:
        print("128 80")
        return
    y, x0, x1 = max(cands, key=lambda s: s[2] - s[1])
    x = max(8, min(224, (x0 + x1) // 2 - BODY_W // 2))
    print(f"{x} {y - 8}")      # a little above it, and settle by falling


if __name__ == "__main__":
    main()
