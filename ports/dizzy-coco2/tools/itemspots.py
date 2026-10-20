#!/usr/bin/env python3
"""Standing spots for harness/items.lua: for every ROU_PICKUPABLE actor in a
built room, the floor the item actually rests on (first surface under the
item's middle, at or below its top+8) and an x beside it. Warping to the
item's own y dropped Dizzy onto whatever platform sits above it.

  tools/itemspots.py > /tmp/itemspots.csv      # idx,room,x,y
"""
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import roomview  # noqa: E402
import exitcases  # noqa: E402

built = set(exitcases.built_rooms())
# sprite sizes from the generated headers: `aspr_N_w fcb w,h,bpr`
SIZES = {}
for f in (HERE.parent / "target").glob("*_data.asm"):
    for m in re.finditer(r"^aspr_(\d+)_w\s+fcb\s+(\d+),(\d+),", f.read_text(), re.M):
        SIZES.setdefault(int(m.group(1)), (int(m.group(2)), int(m.group(3))))
actors = (HERE.parent / "target" / "actor_data.asm").read_text()
table = actors.split("actor_table", 1)[-1] if "actor_table" in actors else actors
print("idx,room,x,y")
idx = 0
for m in re.finditer(r"^\s*fcb (\d+),(\d+),(\d+),(\d+),(\d+),\d+,\d+,\d+\s*;", actors, re.M):
    room, rou, x, y, frm = map(int, m.groups())
    if rou == 2 and room in built:
        rows = roomview.load_mask(room)
        w, h = SIZES.get(frm, (16, 16))
        # the first walkable top edge at or just above the item's BOTTOM, under
        # any of its columns: table tops and ledges, not the room floor below
        fy = None
        c0, c1 = max(0, x // roomview.CELL), min(roomview.CM_COLS - 1, (x + w - 1) // roomview.CELL)
        for r in range(max(0, (y + h - 4) // roomview.CELL), roomview.CM_ROWS):
            if any(rows[r][c] and (r == 0 or not rows[r - 1][c]) for c in range(c0, c1 + 1)):
                fy = r * roomview.CELL
                break
        wx = max(8, min(224, ((x - 4) // 4) * 4))
        # exactly on the item's floor (dropping from above lands on any
        # platform overhead; the early misses on the floor were a SPACE still
        # held from box dismissing, since fixed in items.lua)
        fy = fy if fy is not None else y + 16
        print(f"{idx},{room},{wx},{max(60, fy)}")
    idx += 1
