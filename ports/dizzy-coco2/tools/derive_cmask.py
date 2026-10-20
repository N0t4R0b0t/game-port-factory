#!/usr/bin/env python3
"""Prove (or disprove) that a room's collision mask is DERIVABLE from its
placements alone, offline, with no emulator.

WHY THIS EXISTS: NOTES.md "LOADING ARCHITECTURE, REVISED" / Change 1 wants
to stop shipping a packed 384-byte collision mask per room (~63 packed
bytes x 52 rooms = 3,276 bytes) and instead build CUR_ROOM_CMASK at
load_room time from the same placement walk the runtime already does to
draw the room. This is the offline check that has to pass BEFORE anyone
writes the 6809 code: re-run tools/roompack's own cmask algorithm in
Python from rooms.json (source placements + attribute bytes, in SOURCE
order) and FRAMES.DAT (the shared sprite bitmaps), and diff the result
against the packed mask actually shipped in target/roomNN_data.asm.

THE SPEC is tools/roompack/src/main.rs's cmask loop (~line 1441-1544).
Two passes, both walking room.things in rooms.json's OWN order (NOT the
y-sorted order the target's room_placements table uses for the draw-time
band index -- see --sorted-check below, this is exactly the risk NOTES.md
flags as "a per-cell test cannot be reproduced at runtime from placements
alone unless that information is shipped"):

  1. attr_cells: paint every placement's 8x8-cell bounding box with its
     OWN effective attribute byte, in room order. A later placement wins
     any cell it also covers, REGARDLESS of whether it is itself solid --
     this is what let room 67's barrel be walked over once a decorative
     placement was drawn on top of it.
  2. cmask: for every placement whose OWN attribute is not dull
     (SOLID_DULL_BIT clear), rasterise its real ink (mirrored about its
     own width first, T0143), and set a 4x4 mask cell only where the ink
     lands in a cell whose FINAL attr_cells entry (from pass 1) is ALSO
     not dull.

Three derivations are computed per room, to separate "does the per-cell
test matter at all" from "is it reproducible from placement ORDER alone":

  naive     -- skip pass 1 entirely; a placement's own dull bit is the
               only test. This is what a runtime that ships nothing but
               a per-placement decorative bit (NOTES.md's free bit 1)
               and draws in ANY order would produce.
  full      -- both passes, room.things in rooms.json's own (source)
               order -- reproduces tools/roompack exactly.
  ysorted   -- both passes, but pass 1 walks placements sorted by y (the
               ONLY order the target's shipped room_placements table
               preserves) -- what a runtime deriving attr_cells from the
               table it already has, in the order it already has it,
               would produce.

Usage:
    tools/derive_cmask.py                 # every built room, summary table
    tools/derive_cmask.py --room 67 --map  # one room, ASCII diff map
    tools/derive_cmask.py --json out.json  # machine-readable per-room detail
"""
import argparse
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FRAMES = ROOT / "research/D3-prior-art/original_source/FRAMES.DAT"
ROOMS_JSON = ROOT / "extracted/rooms.json"
TARGET = ROOT / "target"

# T0187: 1px VERTICAL resolution, matching the target's CUR_ROOM_CMASK.
# The original's checkline calls getbyte, which fetches a screen BYTE
# (8px wide, ONE pixel row), so rounding py to a 4px cell made every
# ceiling up to 3px too thick. Columns stay 4px.
CM_COLS, CM_ROWS = 64, 192         # 4px columns, 1px rows, over 256x192
CM_STRIDE = CM_COLS // 8           # 8 bytes/row
CM_LEN = CM_STRIDE * CM_ROWS       # 1536
ATTR_CELLS_W, ATTR_CELLS_H = 32, 24  # 8px cells over 256x192
SOLID_DULL_BIT = 0x40
MIRROR_BIT = 0x80

BUILT_ROOMS = [2, 22, 23, 24, 35, 36, 39, 50, 51, 52, 53, 54, 55, 56, 57,
               58, 59, 60, 67, 68, 69, 70, 71, 72, 83, 84, 85, 86, 87, 100, 76]

# T0233: the tape-only region's own rooms (target/room36.asm's TAPE_ROOMS
# block) -- these do NOT exist in the -run build (room36.bin) at all, so
# they need their own list, selected by CMASK_TAPE=1 (env var, matching
# harness/cmaskverify.lua's own CMASK_TAPE switch -- see its header).
# Room 77 (THE ACTIVE VOLCANO) is not here: not built this round, see
# tools/regen_art.sh's own note (a pre-existing roompack water-tile
# limitation, not this list).
TAPE_BUILT_ROOMS = [74, 75, 63, 91, 92, 45, 48, 49, 94, 89, 41, 73, 88, 93,
                     40, 46, 31, 47, 77]


# T0232: tape-only dc_patch entries (room36.asm dc_patch_tab, `if TAPE_ROOMS`)
# that the "full" derivation cannot produce, because they are the framebuffer-
# scan ink of a DULL placement (room 47: the thatch roof, frame 201, shows
# through the solid attribute that blank frame 58 paints over one 8x8 cell, so
# the original's checkline+checkattri stands Dizzy on feet y=71 at x 136..152).
# (room, first row, col-byte, or-byte, rows): the dump for harness/cmaskverify.lua
# ORs these in so it expects what dc_patch paints.  Rows are 4-row groups in the
# asm (two entries, 72..75 and 76..79).
DC_PATCH_TAPE = [(47, 72, 4, 0x03, 8)]


def apply_dc_patch(room, mask, force=False):
    if not force and os.environ.get("CMASK_TAPE") != "1":
        return mask
    m = bytearray(mask)
    for r, row0, cb, orb, nrows in DC_PATCH_TAPE:
        if r == room:
            for row in range(row0, row0 + nrows):
                m[row * CM_STRIDE + cb] |= orb
    return bytes(m)


# --- FRAMES.DAT decode (verified byte-identical to the target's own art
# by tools/verify_verbatim.py; copied from there rather than re-derived,
# so a decode bug can't quietly disagree with the tool that already
# checks this against every shipped sprite). ------------------------------

def load_frames():
    sections, cur = {}, None
    for line in FRAMES.read_text().splitlines():
        s = line.strip()
        if not s:
            continue
        if s.startswith("HEX"):
            if cur:
                sections[cur] += s[3:].strip()
        elif re.fullmatch(r"\w+", s):
            cur = s
            sections.setdefault(cur, "")
    return bytes.fromhex(sections["frmtable"]), bytes.fromhex(sections["frmdefs"])


def decode(tbl, defs, frame):
    off = tbl[frame * 2] | (tbl[frame * 2 + 1] << 8)
    if off >= 0xFF00 or off + 2 > len(defs):
        return None
    units = defs[off] & 0x7F
    height = defs[off + 1]
    width = units * 4
    src_bpr = (units + 1) // 2
    dst_bpr = (width + 7) // 8
    if width == 0 or height == 0:
        return None
    out = bytearray(dst_bpr * height)
    for r in range(height):
        for c in range(width):
            b = defs[off + 2 + r * src_bpr + c // 8]
            if (b >> (7 - (c % 8))) & 1:
                out[r * dst_bpr + c // 8] |= 1 << (7 - (c % 8))
    return width, height, bytes(out)


def mirror(width, height, bpr, data):
    out = bytearray(len(data))
    for r in range(height):
        for c in range(width):
            if (data[r * bpr + c // 8] >> (7 - (c % 8))) & 1:
                d = width - 1 - c
                out[r * bpr + d // 8] |= 1 << (7 - (d % 8))
    return bytes(out)


_decode_cache = {}


def decode_cached(tbl, defs, frame):
    if frame not in _decode_cache:
        _decode_cache[frame] = decode(tbl, defs, frame)
    return _decode_cache[frame]


# --- rooms.json ------------------------------------------------------------

def load_room_things(room_index):
    data = json.loads(ROOMS_JSON.read_text())
    for r in data["rooms"]:
        if r["index"] == room_index:
            return r["things"]
    return None


def effective_attrs(things):
    out = []
    inherited = 0
    for t in things:
        if not t["same_colour_as_previous"] and t["attribute_byte"] is not None:
            inherited = t["attribute_byte"]
        out.append(inherited)
    return out


# --- the derivation itself --------------------------------------------------

def derive(tbl, defs, things, order, use_percell, all_ink=False):
    """order: sequence of indices into `things` (and its effective attrs)
    giving the order pass 1 (attr_cells) walks them in. Pass 2 (the actual
    mask) always walks placements in rooms.json's own order -- ink drawing
    is OR-composited (roompack's own comment: order can't change drawn
    pixels), so only pass 1's LAST-WRITER-WINS attribute painting is
    order-sensitive."""
    attrs = effective_attrs(things)
    attr_cells = [0] * (ATTR_CELLS_W * ATTR_CELLS_H)
    if use_percell:
        for i in order:
            t, inherited = things[i], attrs[i]
            dec = decode_cached(tbl, defs, t["frame"])
            if dec is None:
                continue
            w, h, _ = dec
            y0, x0 = t["y"], t["pixel_x"]
            if x0 < 0:
                # Rust builds this range from `t.pixel_x as usize`: a
                # negative i32 cast to usize wraps to a huge value, so the
                # whole range is empty and the placement contributes
                # NOTHING to attr_cells either -- not a clamp, a drop.
                # These are exactly roompack's "off the left edge at
                # spawn" placements (its own eprintln, ~line 1173),
                # already dropped from the drawn placement list too.
                continue
            for cy in range(y0 // 8, (y0 + h - 1) // 8 + 1):
                if cy >= ATTR_CELLS_H:
                    continue
                for cx in range(x0 // 8, (x0 + w - 1) // 8 + 1):
                    if cx >= ATTR_CELLS_W:
                        continue
                    attr_cells[cy * ATTR_CELLS_W + cx] = inherited

    cmask = bytearray(CM_LEN)
    solid_count = 0
    for t, inherited in zip(things, attrs):
        # all_ink=True is T0209's "framebuffer scan" oracle: the FRAMEBUFFER
        # holds every placement's ink, decorative ones included, so a probe
        # that reads the screen (as X-ALL.TXT's `checkline` does) cannot skip
        # them here. The per-cell attr test below is then the ONLY filter --
        # which is exactly the original's checkline+checkattri pair.
        if not all_ink and inherited & SOLID_DULL_BIT:
            continue
        solid_count += 1
        dec = decode_cached(tbl, defs, t["frame"])
        if dec is None:
            continue
        w, h, packed = dec
        bpr = (w + 7) // 8
        if inherited & MIRROR_BIT:
            packed = mirror(w, h, bpr, packed)
        y0, x0 = t["y"], t["pixel_x"]
        for row in range(h):
            py = y0 + row
            if py >= 192:
                continue
            for px_i in range(w):
                byte = packed[row * bpr + px_i // 8]
                if not (byte >> (7 - (px_i % 8))) & 1:
                    continue
                px = x0 + px_i
                # Rust computes this per-pixel as `t.pixel_x as usize +
                # px_i`. `as usize` on a negative i32 wraps to a huge u64
                # (2^64 + x0), and in a --release build integer overflow
                # on the ADD wraps too, so px_i large enough to push the
                # sum back past 2^64 lands EXACTLY on the true on-screen
                # pixel (x0+px_i, unwrapped) -- i.e. a placement that
                # starts a few px off the left edge still contributes its
                # ON-SCREEN portion to the mask, even though (per
                # roompack's own warning) it is dropped from the DRAWN
                # placement list entirely, which `blit` cannot clip.
                # Emulated directly here: skip only the truly negative
                # (still-off-screen) pixels, not the whole placement.
                if px < 0 or px >= 256:
                    continue
                if use_percell and attr_cells[(py // 8) * ATTR_CELLS_W + px // 8] & SOLID_DULL_BIT:
                    continue
                cc, cr = px // 4, py          # T0187: py, not py // 4
                cmask[cr * CM_STRIDE + cc // 8] |= 1 << (7 - (cc % 8))
    return bytes(cmask), solid_count


# --- reference mask, unpacked from the shipped, LZSS-packed target file ---

def _lz_unpack(p):
    u, bits, out = 0, 0x80, bytearray()

    def getbit():
        nonlocal u, bits
        carry = bits & 0x80
        bits = (bits << 1) & 0xFF
        if bits:
            return carry != 0
        b = p[u]
        u += 1
        bits = ((b << 1) | 1) & 0xFF
        return (b & 0x80) != 0

    def gamma():
        v = 1
        while not getbit():
            v = (v << 1) | getbit()
        return v

    after_lit, last = False, 1
    while True:
        if not getbit():
            n = gamma()
            if not after_lit:
                out += p[u:u + n]
                u += n
                after_lit = True
            else:
                for _ in range(n):
                    out.append(out[-last])
                after_lit = False
        else:
            m = gamma()
            if m == 256:
                return bytes(out)
            last = (((m - 1) << 8) | p[u]) + 1
            u += 1
            for _ in range(gamma() + 1):
                out.append(out[-last])
            after_lit = False


def load_reference_mask(room):
    path = TARGET / f"room{room}_data.asm"
    body = path.read_text().split(f"r{room}_room_cmask_lz", 1)
    if len(body) < 2:
        return None
    packed = bytearray()
    for line in body[1].splitlines():
        hexes = re.findall(r"\$([0-9a-fA-F]{2})", line)
        if hexes:
            packed += bytes(int(h, 16) for h in hexes)
        elif packed:
            break
    raw = _lz_unpack(bytes(packed))
    if len(raw) != CM_LEN:
        return None
    return raw


# --- reporting ---------------------------------------------------------

def diff_report(a, b):
    """-> (bytes_differing, cells_differing, [(row,col_lo,col_hi), ...] coarse)"""
    byte_diff = sum(1 for x, y in zip(a, b) if x != y)
    cell_diff = 0
    rows_hit = set()
    for r in range(CM_ROWS):
        for c in range(CM_COLS):
            bi, bit = r * CM_STRIDE + c // 8, 7 - (c % 8)
            if ((a[bi] >> bit) & 1) != ((b[bi] >> bit) & 1):
                cell_diff += 1
                rows_hit.add(r)
    return byte_diff, cell_diff, sorted(rows_hit)


def ascii_map(ref, derived):
    """One char per 4px cell: '.' both clear, '#' both set, '+' ref solid
    only (derived missed it), '-' derived solid only (derived over-adds)."""
    lines = []
    for r in range(CM_ROWS):
        row = []
        for c in range(CM_COLS):
            bi, bit = r * CM_STRIDE + c // 8, 7 - (c % 8)
            rv = (ref[bi] >> bit) & 1
            dv = (derived[bi] >> bit) & 1
            row.append('#' if rv and dv else '.' if not rv and not dv else '+' if rv else '-')
        lines.append("".join(row))
    return lines


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--room", type=int, help="check a single room, print an ASCII diff map")
    ap.add_argument("--map", action="store_true", help="with --room, print the ASCII diff map ('full' derivation)")
    ap.add_argument("--json", help="write per-room detail to this path")
    ap.add_argument("--dump-fbscan",
                     help="T0208: like --dump-expected, but the FRAMEBUFFER-SCAN "
                          "derivation (all_ink=True -- every placement's ink is on "
                          "the screen, so only the per-cell attribute test filters "
                          "it). This is the reference harness/cmaskverify.lua must "
                          "diff an FB_CMASK=1 build against; diffing it against "
                          "--dump-expected instead reports the 931 intended cells "
                          "as failures.")
    ap.add_argument("--dump-expected",
                     help="write each BUILT_ROOMS room's 'full' mask (the ground truth -- "
                          "see the note above main()), concatenated 384 bytes/room in "
                          "BUILT_ROOMS order, to this path. This is what harness/"
                          "cmaskverify.lua now diffs the 6809's derived CUR_ROOM_CMASK "
                          "against, since T0166 removed the shipped mask this script used "
                          "to lean on as its own reference.")
    ap.add_argument("--dump-stalk",
                     help="T0223: write the 'full' mask of room 58 + room 1's placements "
                          "appended (the grown beanstalk, X-ALL.TXT checkbeanstalk: "
                          "drawfullroom of room 1 over room 58), CM_LEN bytes, to this path. "
                          "harness/tape_beanstalk.lua (CMASK_STALK=) diffs the 6809's "
                          "derived CUR_ROOM_CMASK against it and exits.")
    args = ap.parse_args()

    tbl, defs = load_frames()
    if args.dump_stalk:
        things = load_room_things(58) + load_room_things(1)
        order = list(range(len(things)))
        full, solid_n = derive(tbl, defs, things, order, use_percell=True)
        Path(args.dump_stalk).write_bytes(bytes(full))
        print(f"wrote {args.dump_stalk}: room 58 ({len(things) - 12} placements) + room 1 (12) = "
              f"{len(things)} placements, {CM_LEN} bytes, {solid_n} solid placements")
        return 0
    default_rooms = TAPE_BUILT_ROOMS if os.environ.get("CMASK_TAPE") == "1" else BUILT_ROOMS
    rooms = [args.room] if args.room else default_rooms

    results = []
    exact_full = exact_naive = exact_ysorted = 0
    percell_matters_rooms = 0
    percell_matters_cells_total = 0
    dump_chunks = []

    # T0166: the shipped, LZSS-packed room_cmask_lz this script used to
    # diff against is GONE (roompack no longer emits it -- load_room now
    # derives the mask itself). `full` (rooms.json + FRAMES.DAT, roompack's
    # own algorithm re-run in Python) is what THAT diff already proved
    # correct against every built room ("Change 1 PROVED OFFLINE": 0
    # bytes, 0 cells different, all 27 rooms) -- so `full` is now this
    # script's own ground truth, not something checked against a second
    # source. Where a shipped mask can still be found (an old build, or a
    # room file someone hasn't regenerated) it's used as an EXTRA check
    # for free; where it can't, this still runs, using `full` as ref.
    print(f"{'room':>5} {'placements':>10} {'ref set':>8} | "
          f"{'naive':>22} | {'full':>22} | {'ysorted':>22}")
    print(f"{'':>5} {'':>10} {'':>8} | {'bytes':>7} {'cells':>7} {'match':>6} | "
          f"{'bytes':>7} {'cells':>7} {'match':>6} | {'bytes':>7} {'cells':>7} {'match':>6}")

    for room in rooms:
        things = load_room_things(room)
        if things is None:
            print(f"room {room}: not found in rooms.json, skipped")
            continue
        shipped_ref = load_reference_mask(room)

        n = len(things)
        order_src = list(range(n))
        order_y = sorted(range(n), key=lambda i: things[i]["y"])

        naive, solid_n = derive(tbl, defs, things, order_src, use_percell=False)
        full, _ = derive(tbl, defs, things, order_src, use_percell=True)
        ysorted, _ = derive(tbl, defs, things, order_y, use_percell=True)

        # `full` is the ground truth (see the note above the room loop);
        # a shipped mask, if one still exists, is an extra cross-check.
        ref = shipped_ref if shipped_ref is not None else full

        if args.dump_expected:
            dump_chunks.append(apply_dc_patch(room, full))
        if args.dump_fbscan:
            dump_chunks.append(derive(tbl, defs, things, order_src,
                                      use_percell=True, all_ink=True)[0])

        ref_set = sum(bin(b).count("1") for b in ref)

        db_naive, dc_naive, rows_naive = diff_report(ref, naive)
        db_full, dc_full, rows_full = diff_report(ref, full)
        db_y, dc_y, rows_y = diff_report(ref, ysorted)

        if dc_full == 0:
            exact_full += 1
        if dc_naive == 0:
            exact_naive += 1
        if dc_y == 0:
            exact_ysorted += 1
        if dc_naive != dc_full or naive != full:
            # does the per-cell test change anything vs. the placement-only test?
            _, cells_between, _ = diff_report(naive, full)
            if cells_between:
                percell_matters_rooms += 1
                percell_matters_cells_total += cells_between

        def fmt(db, dc, rows):
            ok = "yes" if dc == 0 else "no"
            return f"{db:7d} {dc:7d} {ok:>6}"

        print(f"{room:5d} {n:10d} {ref_set:8d} | {fmt(db_naive, dc_naive, rows_naive)} | "
              f"{fmt(db_full, dc_full, rows_full)} | {fmt(db_y, dc_y, rows_y)}")

        results.append(dict(
            room=room, placements=n, solid_placements=solid_n, ref_set_cells=ref_set,
            naive=dict(byte_diff=db_naive, cell_diff=dc_naive, rows=rows_naive),
            full=dict(byte_diff=db_full, cell_diff=dc_full, rows=rows_full),
            ysorted=dict(byte_diff=db_y, cell_diff=dc_y, rows=rows_y),
        ))

        if args.room and args.map:
            print(f"\nroom {room}: 'full' derivation vs reference "
                  f"('#'=both solid '.'=both clear '+'=ref only(missed) '-'=derived only(extra))")
            for line in ascii_map(ref, full):
                print("  " + line)

    n = len(results)
    print(f"\n{n} rooms checked.")
    print(f"  naive (per-placement dull bit only, no per-cell attr test): {exact_naive}/{n} exact")
    print(f"  full  (roompack's own algorithm, source order):             {exact_full}/{n} exact")
    print(f"  ysorted (per-cell test, but pass-1 order = y-sorted):       {exact_ysorted}/{n} exact")
    print(f"\nrooms where the per-cell attribute test changes the outcome vs "
          f"a pure per-placement test: {percell_matters_rooms}/{n} "
          f"({percell_matters_cells_total} cells total)")

    if args.json:
        Path(args.json).write_text(json.dumps(results, indent=2))
        print(f"\nwrote {args.json}")

    out_path = args.dump_expected or args.dump_fbscan
    if out_path:
        Path(out_path).write_bytes(b"".join(dump_chunks))
        print(f"\nwrote {out_path} ({len(dump_chunks)} rooms x {CM_LEN} bytes, "
              f"BUILT_ROOMS order -- harness/cmaskverify.lua's own ROOMS list must match)")

    return 0 if exact_full == n else 1


if __name__ == "__main__":
    sys.exit(main())
