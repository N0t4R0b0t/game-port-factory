#!/usr/bin/env python3
"""T0231: dump every room's collision mask (the 1-pixel-row mask CUR_ROOM_CMASK holds: 192 rows x 8 bytes, bit 7 =
leftmost 4px cell) to target/pt_masks/roomNN.msk, for harness/playthrough.lua's arrival look-ahead (does Dizzy land
on his feet in the NEXT room?).  Static scenery only: no actors, no stalk.  Usage: tools/pt_dump_masks.py [outdir]"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import roomview  # noqa: E402

out = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "target" / "pt_masks")
out.mkdir(parents=True, exist_ok=True)
n = 0
for room in range(128):
    rows = roomview.load_mask(room)
    if not rows:
        continue
    data = bytearray()
    for row in rows:
        for b in range(8):
            v = 0
            for k in range(8):
                if row[b * 8 + k]:
                    v |= 0x80 >> k
            data.append(v)
    assert len(data) == 1536, (room, len(data))
    (out / f"room{room}.msk").write_bytes(bytes(data))
    n += 1
print(f"pt_dump_masks: {n} rooms -> {out}")
