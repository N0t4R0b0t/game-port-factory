#!/usr/bin/env python3
"""Render a built room's COLLISION MASK as text, and list the surfaces
Dizzy can actually stand on.

WHY THIS EXISTS: twice now a bug has been chased with blind walk tests
in MAME that never reached the geometry in question.

  * T0079/T0080 -- "can a border fit?" was answered wrongly twice from
    memory before anyone looked at the real extents.
  * T0081 -- a climb refusal shipped unverified because the test walk
    went left along the floor and never found room 51's staircase. That
    staircase turned out to be 16px steps climbing up-LEFT, which one
    screen of ASCII made obvious instantly. Two failed MAME runs, then
    thirty seconds of looking.

Reads the GENERATED data (target/roomNN_data.asm), not rooms.json, so
what you see is what the target actually collides against -- including
anything roompack dropped or clipped on the way through.

  tools/roomview.py 51              # the mask, with the play window marked
  tools/roomview.py 51 --surfaces   # walkable surface runs, top to bottom
  tools/roomview.py --hidden        # T0086: solid cells above the window, and are any reachable?
  tools/roomview.py --above-line    # every built room: surfaces Dizzy
                                    # could stand on ABOVE the transition
                                    # line, which is the T0081 bug class

Cells are 4x4 pixels (the mask is 64x48 for a 256x192 screen), so a
surface at mask row r has its top edge at y = r*4.
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TARGET = ROOT / "target"
FRAMES = ROOT / "research/D3-prior-art/original_source/FRAMES.DAT"
ROOMS_JSON = ROOT / "extracted/rooms.json"

sys.path.insert(0, str(Path(__file__).resolve().parent))
import derive_cmask as _dc  # noqa: E402  (hoisted: the constants below need it)

# T0188: take the mask geometry FROM the one derivation (_dc), never a
# second copy. The mask went to 1px rows (48 -> 192) and these local
# constants did not: load_mask then decoded only the first 384 bytes --
# the top 48 PIXEL rows, i.e. sky -- and returned an all-clear mask for
# most rooms. tools/start_pos.py, which imports these, fell back to its
# "no mask" default of 128,80, and in room 68 that is inside the
# fireplace: "dizzy spawns in the fireplace, dies right away". This
# file's own header already warns that a second copy is how the T0106
# decoder broke; the constants were the copy that was left.
CM_ROWS, CM_COLS = _dc.CM_ROWS, _dc.CM_COLS
CM_STRIDE = _dc.CM_STRIDE
CM_LEN = _dc.CM_LEN
ROW_PX = 192 // CM_ROWS    # px per mask ROW (1 since T0187)
COL_PX = 256 // CM_COLS    # px per mask COLUMN (4, unchanged)
CELL = ROW_PX              # kept for callers that only mean rows
ATTR_CELLS_W, ATTR_CELLS_H = 32, 24  # 8px cells over 256x192
SOLID_DULL_BIT = 0x40
MIRROR_BIT = 0x80

# Kept in sync with room36.asm by hand -- small enough that reading them
# out of the asm would cost more than it saves, but if a playtest ever
# disagrees with this tool, check these first.
WINDOW_TOP = 48     # X-ALL.TXT windowtop    = 6*8
WINDOW_BOTTOM = 184  # X-ALL.TXT windowbottom = 192-8
TOP_TRANSITION_Y = 68   # T0232: was 66; the port feet y is the original's +1, X-ALL leaves at y<=66 => port y<=67
BUILT = [2, 22, 23, 24, 35, 36, 39, 50, 51, 52, 53, 54, 55, 56, 57,
         58, 59, 60, 67, 68, 69, 70, 71, 72, 83, 84, 85, 86, 87, 100, 76]


# --- the mask, from the ONE derivation that exists -------------------------
#
# Change 1 removed the shipped packed masks; the mask is now derived, both by
# the 6809 runtime at load_room time and offline by tools/derive_cmask.py.
# derive_cmask.py IS the offline ground truth the runtime is verified against
# (harness/cmaskverify.lua diffs the live buffer against its dump), so this
# tool IMPORTS it rather than carrying a second copy of the algorithm. Two
# copies of a subtle two-pass rule do not "stay in sync forever" -- they drift,
# and then there are two ground truths and no way to tell which is right.


def load_mask(room):
    """-> list of CM_ROWS rows, each a list of 64 bools (True = solid), or None."""
    try:
        things = _dc.load_room_things(room)
    except Exception:
        return None
    if not things:
        return None
    tbl, defs = _dc.load_frames()
    order = list(range(len(things)))
    packed = _dc.derive(tbl, defs, things, order, True)[0]   # (mask, attr_cells)
    packed = _dc.apply_dc_patch(room, packed, force=True)    # T0232: tape-only dc_patch cells (room 47 thatch)
    rows = []
    for r in range(CM_ROWS):
        row = []
        for c in range(CM_COLS):
            byte = packed[r * CM_STRIDE + (c >> 3)]
            row.append(bool(byte >> (7 - (c & 7)) & 1))
        rows.append(row)
    return rows

def surfaces(rows):
    """Walkable surface runs: a cell that is solid with nothing solid
    directly above it is a top edge. Returns [(y, x0, x1)] in pixels,
    x1 exclusive."""
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


def render(room, rows, show_surfaces):
    print(f"=== room {room} collision mask (cells are {CELL}x{CELL}px) ===")
    print("     " + "".join(str((c // 10) % 10) for c in range(CM_COLS)))
    print("     " + "".join(str(c % 10) for c in range(CM_COLS)))
    for r, row in enumerate(rows):
        y = r * CELL
        note = ""
        if y == WINDOW_TOP:
            note = "  <-- WINDOW_TOP: nothing above here is drawn"
        elif y <= TOP_TRANSITION_Y < y + CELL:
            note = "  <-- TOP_TRANSITION_Y: feet above this leave the room"
        elif y == WINDOW_BOTTOM:
            note = "  <-- WINDOW_BOTTOM"
        print(f"y{y:3} " + "".join("#" if c else "." for c in row) + note)
    if show_surfaces:
        print()
        print("walkable surfaces (top edges), highest first:")
        for y, x0, x1 in sorted(surfaces(rows)):
            flag = ""
            if y < TOP_TRANSITION_Y:
                flag = "   ** above TOP_TRANSITION_Y"
            print(f"   y={y:3}  x={x0:3}..{x1:<3}{flag}")


def above_line_report():
    """The T0081 bug class: a surface Dizzy can stand on above the
    transition line only behaves sanely if the room ABOVE is built --
    otherwise the transition is denied and he is left standing outside
    the play window."""
    print(f"Surfaces above TOP_TRANSITION_Y={TOP_TRANSITION_Y}, per built room.")
    print("A room whose UP neighbour is NOT built is where Dizzy can end up")
    print("stranded above the play window (see NOTES.md T0081).\n")
    for room in BUILT:
        rows = load_mask(room)
        if rows is None:
            print(f"  room {room}: no mask found")
            continue
        high = [s for s in surfaces(rows) if s[0] < TOP_TRANSITION_Y]
        up = (room + 16) & 127
        built = "built" if up in BUILT else "NOT BUILT"
        if not high:
            print(f"  room {room}: none.  (up = {up}, {built})")
            continue
        print(f"  room {room}: {len(high)} surface(s) above the line."
              f"  up = {up}, {built}"
              + ("   <-- can strand Dizzy" if up not in BUILT else ""))
        for y, x0, x1 in sorted(high):
            print(f"       y={y:3}  x={x0:3}..{x1}")


def hidden_report():
    """T0086: collision cells ABOVE the play window. The port's mask is
    precomputed from every placement, so they stay solid; the original
    collides on drawn screen attributes, so a sprite clipped out of the
    window does not collide at all. The mismatch only matters if such a
    cell can be REACHED: every hidden column capped by solid at WINDOW_TOP
    is untouchable from inside the window, and standing on top of one puts
    Dizzy's feet above TOP_TRANSITION_Y, which leaves the room. Returns 1
    if any built room has an uncapped hidden column, so it can gate a
    build when new rooms arrive."""
    top_row = WINDOW_TOP // CELL
    bad = 0
    print(f"Solid cells above WINDOW_TOP={WINDOW_TOP}, per built room (NOTES.md T0086).\n")
    for room in BUILT:
        rows = load_mask(room)
        if rows is None:
            print(f"  room {room}: no mask found")
            continue
        hidden = [(r, c) for r in range(top_row) for c in range(CM_COLS) if rows[r][c]]
        if not hidden:
            print(f"  room {room}: none.")
            continue
        cols = sorted({c for _, c in hidden})
        uncapped = [c for c in cols if not rows[top_row][c]]
        if uncapped:
            bad += 1
            print(f"  room {room}: {len(hidden)} hidden cell(s); UNCAPPED at x="
                  f"{[c * CELL for c in uncapped]}  <-- reachable from inside the window, and invisible")
        else:
            print(f"  room {room}: {len(hidden)} hidden cell(s) at x={cols[0] * CELL}..{(cols[-1] + 1) * CELL},"
                  f" all capped by solid at y={WINDOW_TOP} -- unreachable")
    return 1 if bad else 0


def main():
    args = [a for a in sys.argv[1:]]
    if "--above-line" in args:
        above_line_report()
        return 0
    if "--hidden" in args:
        return hidden_report()
    show_surfaces = "--surfaces" in args
    rooms = [a for a in args if not a.startswith("--")]
    if not rooms:
        print(__doc__)
        return 2
    for room in rooms:
        room_idx = int(room)
        rows = load_mask(room_idx)
        if rows is None:
            print(f"room {room}: ERROR: cannot load mask. Room must be in rooms.json "
                  f"with valid placements and sprite data.", file=sys.stderr)
            return 1
        render(room_idx, rows, show_surfaces)
    return 0


if __name__ == "__main__":
    sys.exit(main())
