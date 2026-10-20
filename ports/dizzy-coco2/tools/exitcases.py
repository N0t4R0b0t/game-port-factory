#!/usr/bin/env python3
"""Generate room-exit test cases for every BUILT room, from the collision
masks the target actually uses (tools/roomview.py's loader).

One case = start on a surface, do one move, see which room Dizzy ends up in
and where he first lands there. harness/exits_port.lua runs the cases on the
port, harness/exits_zx.lua on the original, tools/exitcompare.py diffs them:
the original is the authority on what is reachable.

Cases, for each built room and each BUILT neighbour:
  up     surfaces a jump can lift through TOP_TRANSITION_Y (feet 66..108; a
         jump rises 36px) -- JUMP, JUMPLEFT, JUMPRIGHT from each end and the
         middle -- plus NONE on anything already above the line
  left   WALK LEFT and JUMPLEFT off surfaces reaching the left edge, and
         JUMPLEFT from surfaces ending within 40px of it
  right  mirror of left
  down   walk off a surface end whose drop is open to the bottom row

Output: CSV id,room,x,y,strat,frames (x in port pixels, multiple of 4; the
ZX runner divides by 4).

  tools/exitcases.py > /tmp/exitcases.csv
"""
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import roomview  # noqa: E402

TOP = roomview.TOP_TRANSITION_Y
CELL = roomview.CELL
BODY = 24           # sprite width; the floor probes sit inside it
JUMP_RISE = 36      # 8+7+...+1


def built_rooms():
    asm = (HERE.parent / "target" / "room36.asm").read_text()
    table = asm.split("room_desc_table", 1)[1].split("fdb 0", 1)[0]
    return [int(n) for n in re.findall(r"fdb r(\d+)_room_desc", table)]


def x4(v):
    return max(0, min(232, (int(v) // 4) * 4))


def clear_above(rows, x, y_from, y_to):
    """Is Dizzy's column open from feet y_from up to y_to (exclusive)?"""
    c0, c1 = x // CELL + 1, (x + BODY) // CELL - 1
    for r in range(max(0, y_to // CELL), max(0, (y_from - 24) // CELL)):
        for c in range(c0, c1 + 1):
            if 0 <= c < roomview.CM_COLS and rows[r][c]:
                return False
    return True


def open_drop(rows, x0, x1, y):
    """Columns x0..x1 clear from row y down to the bottom of the mask?"""
    for r in range(y // CELL, roomview.CM_ROWS):
        for c in range(max(0, x0 // CELL), min(roomview.CM_COLS, x1 // CELL)):
            if rows[r][c]:
                return False
    return True


def hazards(room):
    """Boxes (x0,y0,x1,y1) a start spot must not touch: the room's flame and
    water tiles (roomNN_data.asm tables) and the deadly actors (actor_data.asm:
    rat, crocodile, dragon, armorog, dagger). A start in one of these is a
    death loop, not an exit test."""
    out = []
    data = (HERE.parent / "target" / f"room{room}_data.asm")
    if data.exists():
        s = data.read_text()
        for kind, w, h in (("flame", 16, 24), ("water", 32, 16)):
            m = re.search(rf"r{room}_room_{kind}_count\s+fcb\s+(\d+)\s*\n\s*r{room}_room_{kind}s?\n((?:\s*fcb[^\n]*\n)*)", s)
            if m:
                for x, y in re.findall(r"fcb\s+(\d+),(\d+)", m.group(2))[:int(m.group(1))]:
                    out.append((int(x) - 8, int(y) - 8, int(x) + w + 8, int(y) + h))
    actors = (HERE.parent / "target" / "actor_data.asm").read_text()
    for m in re.finditer(r"fcb (\d+),(\d+),(\d+),(\d+),\d+,\d+,\d+,\d+\s*;", actors):
        r_, rou, x, y = map(int, m.groups())
        if r_ == room and rou in (3, 4, 5, 11, 13):      # armorog dragon croc rat dagger
            out.append((x - 24, y - 16, x + 56, y + 40))
    return out


def in_hazard(boxes, x, y):
    return any(x < x1 and x + BODY > x0 and y > y0 and y - 24 < y1 for x0, y0, x1, y1 in boxes)


def main():
    built = set(built_rooms())
    cases, seen = [], set()

    skipped = []

    def add(kind, room, x, y, strat, frames):
        key = (room, x4(x), y, strat)
        if key in seen:
            return
        if in_hazard(hazards(room), x4(x), y):
            seen.add(key)
            skipped.append(key)
            return
        seen.add(key)
        cases.append((f"{room}{kind}{len([c for c in cases if c[0].startswith(f'{room}{kind}')])}",
                      room, x4(x), y, strat, frames))

    for room in sorted(built):
        rows = roomview.load_mask(room)
        if rows is None:
            continue
        surf = roomview.surfaces(rows)
        up, left, right, down = (room + 16) & 127, room - 1, room + 1, (room - 16) & 127
        for y, a, b in surf:
            if b - a < 12 or y > 180:
                continue
            spots = sorted({x4(a), x4((a + b) / 2 - BODY / 2), x4(b - BODY)})
            if up in built:
                if y < TOP:
                    add("u", room, spots[len(spots) // 2], y, "NONE", 150)
                elif y <= TOP + JUMP_RISE + 6:
                    for x in spots:
                        if clear_above(rows, x, y, TOP):
                            add("u", room, x, y, "JUMP", 170)
                        add("u", room, x, y, "JUMPLEFT", 170)
                        add("u", room, x, y, "JUMPRIGHT", 170)
            if left in built:
                if a <= 12:
                    add("l", room, a + 8, y, "LEFT", 220)
                    add("l", room, a + 16, y, "JUMPLEFT", 170)
                elif a <= 40:
                    add("l", room, a, y, "JUMPLEFT", 170)
            if right in built:
                if b >= 244:
                    add("r", room, b - 32, y, "RIGHT", 220)
                    add("r", room, b - 40, y, "JUMPRIGHT", 170)
                elif b >= 216:
                    add("r", room, b - BODY, y, "JUMPRIGHT", 170)
            if down in built:
                if a >= 24 and open_drop(rows, a - 20, a, y):
                    add("d", room, a, y, "LEFT", 220)
                if b <= 232 and open_drop(rows, b, b + 20, y):
                    add("d", room, b - BODY, y, "RIGHT", 220)

    print("id,room,x,y,strat,frames")
    for c in cases:
        print(",".join(str(v) for v in c))
    print(f"{len(cases)} cases over {len(built)} built rooms, {len(skipped)} hazard starts skipped", file=sys.stderr)


if __name__ == "__main__":
    main()
