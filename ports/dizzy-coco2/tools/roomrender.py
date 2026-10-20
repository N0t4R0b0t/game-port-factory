#!/usr/bin/env python3
"""Render every room from GENERATED room data and compare two data sets.

Why this exists: harness/framedump.lua dumps the framebuffer at a FIXED
FRAME NUMBER. That is only comparable between two builds that boot at the
same speed. T0142 made the staged data ~900 bytes smaller, the unpack got
faster, and every room's dump then differed by the same 1025 bytes -- an
intro message box still up in one build and gone in the other, not a
rendering change at all. Rooms with flames/water/actors never re-align at
any later frame either, because their animation phase is counted in
passes since boot.

This compares what actually matters -- the composed room bitmap -- with no
emulator and no timing at all:

  tools/roomrender.py DIR_A DIR_B

where each DIR holds a set of generated room*_data.asm plus
shared_sprites_data.asm / shared_sprites_overflow_data.asm. Placement x
carries T0142's mirror flag in bit 0, which is applied here exactly as
blit's blit_mkrev does it.

T0167: a placement record used to be `fdb name_w` + `fcb x,y` (a direct
sprite pointer). It is now `fcb index` + `fcb x,y` -- a 1-byte index into
the global frame_table_data.asm (index -> sprite header address), also
in DIR if present. Both forms are recognised here so this still compares
a pre-T0167 DIR against a post-T0167 one.
"""
import re
import sys
import glob


def load_frame_table(d):
    # frame_table_data.asm: `frame_table` label followed by one
    # `\tfdb name_w` per index, in index order (T0167).
    table = []
    for f in glob.glob(f"{d}/frame_table_data.asm"):
        for m in re.finditer(r"^\s*fdb\s+(\w+)_w", open(f).read(), re.M):
            table.append(m.group(1))
    return table


def load_set(d):
    blob = "\n".join(open(f).read() for f in glob.glob(f"{d}/*.asm"))
    sprites = {}
    for m in re.finditer(
        r"^(\w+)_w\s+fcb\s+(\d+)\s*\n\s*\1_h\s+fcb\s+(\d+)\s*\n\s*\1_bpr\s+fcb\s+(\d+)"
        r"\s*\n\s*\1\s+fcb\s+([^\n]*(?:\n\s+fcb[^\n]*)*)", blob, re.M):
        name, w, h, bpr = m.group(1), int(m.group(2)), int(m.group(3)), int(m.group(4))
        vals = [int(t, 16) for t in re.findall(r"\$([0-9a-fA-F]{2})", m.group(5))]
        if len(vals) >= h * bpr:
            sprites[name] = (w, h, bpr, vals[:h * bpr])
    frame_table = load_frame_table(d)
    rooms = {}
    for m in re.finditer(r"^r(\d+)_room_placements\s*\n(.*?)^r\1_room_placements_end",
                         blob, re.M | re.S):
        body = m.group(2)
        placements = [
            (pm.group(1), int(pm.group(2)), int(pm.group(3)))
            for pm in re.finditer(r"fdb\s+(\w+)_w\s*\n\s*fcb\s+(\d+),(\d+)", body)]
        for pm in re.finditer(r"^\s*fcb\s+(\d+)\s*\n\s*fcb\s+(\d+),(\d+)\s*$", body, re.M):
            idx = int(pm.group(1))
            name = frame_table[idx] if idx < len(frame_table) else f"<bad-index-{idx}>"
            placements.append((name, int(pm.group(2)), int(pm.group(3))))
        rooms[int(m.group(1))] = placements
    return sprites, rooms


def render(sprites, placements):
    fb = [bytearray(32) for _ in range(192)]
    missing = set()
    for name, x, y in placements:
        mirror = x & 1                    # T0142: bit 0 of a placement's x
        px = x & 0xfe
        s = sprites.get(name)
        if not s:
            missing.add(name)
            continue
        w, h, bpr, data = s
        for r in range(h):
            if y + r >= 192:
                break
            row = data[r * bpr:(r + 1) * bpr]
            for c in range(w):
                src = w - 1 - c if mirror else c
                if (row[src >> 3] >> (7 - (src & 7))) & 1 and px + c < 256:
                    fb[y + r][(px + c) >> 3] |= 1 << (7 - ((px + c) & 7))
    return b"".join(bytes(r) for r in fb), missing


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sa, ra = load_set(sys.argv[1])
    sb, rb = load_set(sys.argv[2])
    print(f"A: {len(sa)} sprites {sum(v[1]*v[2] for v in sa.values())} bytes, {len(ra)} rooms")
    print(f"B: {len(sb)} sprites {sum(v[1]*v[2] for v in sb.values())} bytes, {len(rb)} rooms")
    bad = 0
    for room in sorted(set(ra) | set(rb)):
        fa, ma = render(sa, ra.get(room, []))
        fb_, mb = render(sb, rb.get(room, []))
        if fa != fb_:
            bad += 1
            print(f"  room {room:3d}: DIFFERS ({sum(i != j for i, j in zip(fa, fb_))} bytes)")
        if ma | mb:
            print(f"  room {room:3d}: unresolved sprites {sorted(ma | mb)[:4]}")
    print(f"rooms differing: {bad}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
