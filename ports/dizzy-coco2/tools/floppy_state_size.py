#!/usr/bin/env python3
"""tools/floppy_state_size.py -- T0241: classify harness/floppy_state_size.lua's RAM diff (S0 = fresh game live in
room 36, S1 = the playthrough bot's checkpoint pt_seg<N>) with ramaudit's row table and the map's symbols:
how many bytes of GAME STATE does a quick-save have to carry?  Prints per-class totals and, for the
code/data-live rows, every differing run with its nearest symbol.
Usage: tools/floppy_state_size.py [SEG]      (default 105; run the lua first, see its header)
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
seg = sys.argv[1] if len(sys.argv) > 1 else "105"
sys.argv = [sys.argv[0], "--floppy"]
sys.path.insert(0, str(ROOT / "tools"))
import ramaudit  # noqa: E402

d = (ROOT / f"target/floppy/state_diff_seg{seg}.bin").read_bytes()
diff = {}
for i in range(0, len(d), 4):
    a = d[i] << 8 | d[i + 1]
    diff[a] = (d[i + 2], d[i + 3])
rows = ramaudit.R
syms = sorted((v, k) for k, v in ramaudit.SYM.items() if k not in ramaudit.EQU_NAMES)


def row_of(a):
    for lo, hi, owner, cls, ev, need in rows:
        if lo <= a < hi:
            return owner, cls
    return "?", "?"


def nearest(a):
    best = None
    for v, k in syms:
        if v <= a:
            best = (v, k)
        else:
            break
    return best


tot = {}
for a in diff:
    o, c = row_of(a)
    tot[c] = tot.get(c, 0) + 1
print(f"differing bytes between a fresh live game and checkpoint pt_seg{seg}: {len(diff)} total")
for c, n in sorted(tot.items(), key=lambda x: -x[1]):
    print(f"  {c:<18} {n}")
live = sorted(a for a in diff if row_of(a)[1] in ("code/data-live", "title-reused"))
print(f"\nGAME STATE candidates (rows classed code/data-live or title-reused that changed): {len(live)} bytes in these runs")
runs = []
for a in live:
    if runs and a <= runs[-1][1] + 3:
        runs[-1][1] = a
    else:
        runs.append([a, a])
for lo, hi in runs:
    n = nearest(lo)
    cnt = sum(1 for a in live if lo <= a <= hi)
    print(f"  ${lo:04X}-${hi:04X} {cnt:4d} B changed  ({row_of(lo)[0][:48]})  near {n[1] if n else '?'}+{lo - n[0] if n else 0}")
