#!/usr/bin/env python3
"""Ledge-edge standing cases, in tools/exitcases.py's CSV format.

Where on a ledge's END can Dizzy still stand? The port's floor probes and
the original's checkline sample different columns, and the mask conversion
rounds placements to 4px, so the two can disagree about an overhang -- which
decides whether a jump lands on a high ledge or falls past it.

For every surface in a built room (y 48..176, at least 16px wide), clear of
hazards, Dizzy is put down (strat NONE) overhanging each end by OVERHANG px
(default 4,8,12,16 -- a negative x for the left end means his body sticks out
past the ledge's left edge). exitcompare's landing y then says, per side,
whether he stayed up or fell.

  tools/edgecases.py > /tmp/edgecases.csv
"""
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import roomview  # noqa: E402
import exitcases  # noqa: E402

BODY = 24
over = [int(v) for v in os.environ.get("OVERHANG", "4,8,12,16").split(",")]
print("id,room,x,y,strat,frames")
n = 0
for room in sorted(exitcases.built_rooms()):
    rows = roomview.load_mask(room)
    if rows is None:
        continue
    boxes = exitcases.hazards(room)
    k = 0
    for y, a, b in roomview.surfaces(rows):
        if y < 48 or y > 176 or b - a < 16:
            continue
        for o in over:
            for side, x in (("L", a - o), ("R", b - BODY + o)):
                if x < 8 or x > 224:
                    continue
                x = exitcases.x4(x)
                if exitcases.in_hazard(boxes, x, y):
                    continue
                print(f"{room}e{side}{k},{room},{x},{y},NONE,80")
                k += 1
                n += 1
print(f"{n} edge cases", file=sys.stderr)
