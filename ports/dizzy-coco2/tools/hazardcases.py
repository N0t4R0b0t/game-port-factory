#!/usr/bin/env python3
"""Hazard test cases, in tools/exitcases.py's CSV format, for the same
runners (harness/exits_port.lua, harness/exits_zx.lua) and the same diff
(tools/exitcompare.py -- BOTH-DIED is agreement, DIFF-DEATH is a finding).

For every built room:
  flame  Dizzy put down on each torch-flame tile (roomNN_data.asm flame table)
  water  ...on each water tile
  actor  ...beside each deadly actor, walking into it: rat, crocodile,
         dragon, armorog, dagger (actor_data.asm)
  safe   one control per room on its widest surface away from all of the
         above, standing still: must NOT die on either side

  tools/hazardcases.py > /tmp/hazardcases.csv
"""
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import roomview  # noqa: E402
import exitcases  # noqa: E402


def floor_under(rows, x, y_from):
    """Feet y of the first surface at or below y_from under Dizzy's middle."""
    c = (x + 12) // roomview.CELL
    for r in range(max(0, y_from // roomview.CELL), roomview.CM_ROWS):
        if rows[r][c] and (r == 0 or not rows[r - 1][c]):
            return r * roomview.CELL
    return None


def main():
    cases = []
    actors = (HERE.parent / "target" / "actor_data.asm").read_text()
    names = {3: "armorog", 4: "dragon", 5: "croc", 11: "rat", 13: "dagger"}
    for room in sorted(exitcases.built_rooms()):
        rows = roomview.load_mask(room)
        if rows is None:
            continue
        data = (HERE.parent / "target" / f"room{room}_data.asm").read_text()
        n = 0
        for kind in ("flame", "water"):
            m = re.search(rf"r{room}_room_{kind}_count\s+fcb\s+(\d+)\s*\n\s*r{room}_room_{kind}s?\n((?:\s*fcb[^\n]*\n)*)", data)
            if not m:
                continue
            for x, y in re.findall(r"fcb\s+(\d+),(\d+)", m.group(2))[:int(m.group(1))]:
                x, y = int(x), int(y)
                # stand ON the tile: feet on its top row (water) or overlapping the flame
                fx = exitcases.x4(x - 4)
                fy = y + (8 if kind == "flame" else 2)
                cases.append((f"{room}{kind[0]}{n}", room, fx, fy, "NONE", 150)); n += 1
        for m in re.finditer(r"fcb (\d+),(\d+),(\d+),(\d+),\d+,\d+,\d+,\d+\s*;", actors):
            r_, rou, x, y = map(int, m.groups())
            if r_ != room or rou not in names:
                continue
            fy = floor_under(rows, x - 32, max(48, y - 8)) or y
            cases.append((f"{room}a{n}", room, exitcases.x4(x - 32), fy, "RIGHT", 220)); n += 1
        # control: widest surface below the line, start clear of every hazard box
        boxes = exitcases.hazards(room)
        best = None
        for y, a, b in roomview.surfaces(rows):
            if y < roomview.TOP_TRANSITION_Y or y > 180 or b - a < 32:
                continue
            x = exitcases.x4((a + b) / 2 - 12)
            if exitcases.in_hazard(boxes, x, y):
                continue
            if best is None or b - a > best[2]:
                best = (x, y, b - a)
        if best:
            cases.append((f"{room}s0", room, best[0], best[1], "NONE", 150))
    print("id,room,x,y,strat,frames")
    for c in cases:
        print(",".join(str(v) for v in c))
    print(f"{len(cases)} hazard/control cases", file=sys.stderr)


if __name__ == "__main__":
    main()
