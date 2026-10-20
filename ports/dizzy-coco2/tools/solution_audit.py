#!/usr/bin/env python3
"""Cost audit for the missing item triggers (read-only; prints tables).

Inputs: X-ALL.TXT message streams + extracted/actors.json coins +
extracted/frmtable.json frame sizes.

Message estimate (calibrated on two shipped tape messages):
  bytes ~= round(0.71 * chars) + 2 + lines
  msg_puteggback: 65 chars, 4 lines -> 52 B measured (formula 52)
  msg_rockinwater: 78 chars, 3 lines -> 59 B measured (formula 60)
Sprite estimate: width*4 px -> bpr = width/2, bytes = bpr*height + 3
  (aspr_5: 16x16 -> 35 B).
"""
import json, re
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
SRC = (ROOT/"research/D3-prior-art/original_source/X-ALL.TXT").read_text(encoding="latin1").splitlines()

def stream(start, end):
    chars = lines = boxes = 0
    for l in SRC[start-1:end]:
        boxes += l.count("drawbox")
        for s in re.findall(r'"([^"]*)"', l):
            chars += len(s); lines += 1
    return chars, lines, boxes

# (name, first line, last line) -- line numbers in X-ALL.TXT
MSGS = [
 ("plantbeanmess", 'plantbeanmess', 'pickupmanuremess'),
 ("throwwateronbeanmess", 'throwwateronbeanmess', 'plantbeanmess'),
 ("fillbucketmess", 'fillbucketmess', 'thanksforloafmess'),
 ("usedoorknockermess", 'usedoorknockermess', 'usecrowbarmess'),
 ("usepickaxemess", 'usepickaxemess', 'obstructingliftmess'),
 ("userugmess", 'userugmess', 'dropwhiskeymess'),
 ("shopkeeperappearsmess", 'shopkeeperappearsmess', 'givingjunkmess'),
 ("givingjunk+stopgiving", 'givingjunkmess', 'shoptalk'),
 ("shoptalk (cow trade, whole stream)", 'shoptalk', 'letsfaceitmess'),
 ("shoptalk minimal (cow+bean boxes)", None, None),
 ("dylantalking+trance", 'dylantalking', 'denziltalking'),
 ("dougtalking", 'dougtalking', 'goonmysonmess'),
 ("daisy: gottodaisy+daisyruns", 'gottodaisymess', 'notgotallcoins'),
 ("dropwhiskeymess", 'dropwhiskeymess', 'getbackintheremess'),
 ("holdingholemess", 'holdingholemess', 'deadwindow'),
 ("pickupmanuremess", 'pickupmanuremess', 'throwswitchmess'),
]
def find(label, after=0):
    for i, l in enumerate(SRC, 1):
        if i > after and re.match(r"^" + re.escape(label) + r"\b", l):
            return i
    raise SystemExit("label not found: " + label)

def est(c, l): return round(0.71 * c) + 2 + l

print("MESSAGE ESTIMATES (GUESS from calibrated formula)")
print(f"{'message':40s} line  chars lines boxes  est_B")
for name, a, b in MSGS:
    if a is None:
        s = find('thanksforthecowmess'); e = find('nottengoldcoins')-1
        c1 = stream(s, e)
        s2 = find('throwsbean'); e2 = find('letsfaceitmess')-1
        c2 = stream(s2, e2)
        c = (c1[0]+c2[0], c1[1]+c2[1], c1[2]+c2[2]); at = s
    else:
        at = find(a); c = stream(at, find(b, at)-1)
    print(f"{name:40s} {at:4d} {c[0]:5d} {c[1]:5d} {c[2]:5d} {est(c[0], c[1]):6d}")

fr = json.load(open(ROOT/"extracted/frmtable.json"))["entries"]
print("\nSPRITE ESTIMATES (MEASURED formula, bpr*h+3)")
for f, n in [(2,'bean'),(105,'shopkeeper'),(146,'rock (room 41)'),(210,'carpet'),(7,'cow (present)'),(169,'dagger (present)')]:
    w, h = fr[f]["width"]*4, fr[f]["height"]
    bpr = w//8 if w % 8 == 0 else w//8+1
    print(f"frame {f:3d} {n:18s} {w}x{h} -> {bpr*h+3} B")

coins = json.load(open(ROOT/"extracted/actors.json"))["coins"]
print("\nCOINS (X-ALL cointable order): idx room raw(x,y) px(x,y)")
for i, c in enumerate(coins, 1):
    print(f"{i:2d} room {c['room']:3d} raw ({c['x']},{c['y']}) px ({c['pixel_x']},{c['y']})")
