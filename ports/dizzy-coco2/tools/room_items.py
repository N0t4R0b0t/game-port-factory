#!/usr/bin/env python3
"""Which carried items does a room's puzzle need? Derived, not guessed.

play.sh uses this so `./play.sh 53` starts you holding the rope.

HOW IT IS DERIVED. Every pickupable in the original carries a `prox`
routine in its movingdata entry, and a prox routine's data block opens
with the ROOM its trigger box lives in:

    proxcroc  defb 53      ;;room
              defb 68,140  ;;;x,y
              defb 10,20   ;;;w,h

`ropehere`'s prox is proxcroc, and proxcroc's box is in room 53 -- so the
rope is the item room 53's puzzle wants, and that fact comes straight out
of X-ALL.TXT rather than from anyone's memory of the game. 20 such
item->room links exist; this reads them every run, so a room built later
picks its items up automatically.

Only frames actually present in target/actor_data.asm can be seeded --
`inv` stores an actor index, so an item whose actor is not in this
build's 20-slot table has nothing to point at. Those are reported on
stderr rather than silently dropped.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "research/D3-prior-art/original_source/X-ALL.TXT"
ACTORS = ROOT / "extracted/actors.json"
ACTOR_ASM = ROOT / "target/actor_data.asm"

# name -> frame, matching play.sh's own table
NAMES = {14: "rope", 17: "apple", 18: "whiskey", 19: "jug", 20: "loaf", 192: "railing"}


def prox_rooms():
    src = SRC.read_text(encoding="latin1")
    pat = re.compile(r"^(\w+)\s+defb\s+(\d+)\s*;;+\s*room", re.M)
    return {m.group(1): int(m.group(2)) for m in pat.finditer(src)}


def seedable_frames():
    if not ACTOR_ASM.exists():
        return set()
    rows = re.findall(r"^\tfcb (\d+),(\d+),(\d+),(\d+),(\d+)", ACTOR_ASM.read_text(), re.M)
    return {int(r[4]) for r in rows}


def main():
    room = int(sys.argv[1])
    rooms = prox_rooms()
    data = json.loads(ACTORS.read_text())
    actors = data["actors"] if isinstance(data, dict) else data
    have = seedable_frames()

    wanted, missing = [], []
    for a in actors:
        if a.get("routine") != "pickupable":
            continue
        if rooms.get(a.get("prox")) != room:
            continue
        frame = a.get("frame")
        if frame in have:
            if frame not in wanted:
                wanted.append(frame)
        else:
            missing.append((frame, a.get("label") or "unnamed"))

    for frame, label in missing:
        print(f"room_items: room {room} wants frame {frame} ({label}) but no actor "
              f"in this build carries it -- not seeded", file=sys.stderr)
    # inv_cap is 3 without the bag
    print(",".join(NAMES.get(f, str(f)) for f in wanted[:3]))


if __name__ == "__main__":
    main()
