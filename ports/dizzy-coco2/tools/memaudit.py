#!/usr/bin/env python3
"""Audit the built DECB image's memory layout.

Exists because two separate bugs got through a SYMBOL-based audit (the
one regen_art.sh describes): a symbol scan sees the last *label* in a
file, not the last *byte*, so a data file whose tail runs past the end
of its region looks clean and loads anyway.

  * room2_data.asm's tail sat 225 bytes inside framebuffer B for
    several sessions.
  * shared_sprites_data.asm's tail reached $7EE0, into `nibswap`, which
    is filled at boot -- blit then read a garbage sprite header and the
    machine reset itself about a second in (T0058).

This reads the actual DECB block list, which is ground truth for what
lands where.

T0075 added a THIRD way this class of bug gets through: two blocks can
each individually sit inside an allowed region and still overlap EACH
OTHER. CLOADM loads blocks in file order, so the later one silently
overwrites the earlier one's bytes for the shared addresses -- no
per-block check catches that, only a cross-block one. This is exactly
how room 55 (T0074) corrupted the tail of actor_data.asm: the r9800
staging block ($6000+, framebuffer B) needed 7489 bytes against a
6144-byte window and ran 1345 bytes into gap2 ($7800+, actor data,
loaded earlier in the file) -- both blocks individually reported
"loads into an allowed region", and the audit said clean, right up
until T0075's own actor growth shifted the overwritten bytes onto a
sprite header that hangs `blit` instead of merely drawing something
wrong.

T0158 fixed a FOURTH class: the per-region "N bytes free" figure was
computed from the highest loaded byte in the region, but mktitle packs
the title screen (+ extra/extra2/music) into whatever load-time holes
are left below $8000 -- see title_holes.py and mktitle.rs -- and it
packs each hole FLUSH to its top boundary by construction (it fills a
hole fully before moving to the next one). So "top of loaded bytes"
reads as the region's END for any region the title screen reached,
whether or not RESIDENT code/data actually uses that space. That read
"0 bytes free" for low data, code+data, framebuffer A, gap1 and
framebuffer B both BEFORE and AFTER T0148 moved 338 bytes of code out
of code+data -- the figure cannot move with resident code size, because
it is measuring the title's packing, not the code. Only gap2 ever told
the truth, because it happens to be the LAST hole mktitle fills, so it
is the only one that can be left partially empty.

The fix: target/title_lz.asm (written by mktitle, one file per build)
carries a `; hole at $ADDR: using N of M bytes` comment for every hole
it actually used, and $ADDR is the hole's start address -- which is
exactly the boundary between genuine resident content and title
back-fill, i.e. what memaudit needs and the raw block scan cannot see
on its own. Parsed and cross-checked against the block scan below.
See NOTES.md's "T0159 -- the delivery budget, costed" section for the
distinction between a region's resident-free bytes (real headroom,
independent of the title) and its free-after-backfill bytes (what is
left over once the title borrowed some of that headroom -- usually
zero, because mktitle borrows greedily).

Run from the port root: tools/memaudit.py [image.bin] [title_lz.asm]
Exit 0 = every loaded byte is in a region that allows loading, AND no
two blocks overlap each other. (The free-space reporting below never
affects the exit code -- it is informational, not a load-correctness
check.)
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
IMG = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "target/room36.bin"
TITLE_LZ = Path(sys.argv[2]) if len(sys.argv) > 2 else IMG.parent / "title_lz.asm"

# (start, end_exclusive, name, may_load)
REGIONS = [
    (0x0000, 0x0100, "stack ($0000-$00FF, grows down from $0100)", False),
    (0x0100, 0x0E00, "low data (room36/room35 art)", True),
    (0x0E00, 0x4000, "code + data", True),
    (0x4000, 0x5800, "framebuffer A / $8000 staging block 1", True),
    (0x5800, 0x6000, "gap1 (dizzy tail, message VM, font, messages)", True),
    (0x6000, 0x7800, "framebuffer B / $8000 staging block 2", True),
    (0x7800, 0x7E00, "gap2 (actor data)", True),
    (0x7E00, 0x8000, "nibswap + rat save-under (built at boot)", False),
    (0x8000, 0x10000, "all-RAM region (filled by the boot relocate)", False),
]

# T0159, measured from rooms 24 + 57 (1227 packed budget bytes for 795 raw
# room bytes): NOT a constant of nature, just the last measurement on
# hand. Re-measure after the next couple of rooms and update this if it
# has drifted -- see NOTES.md's "T0159" section for the method.
MEASURED_PACKED_BYTES_PER_ROOM = 614

HOLE_RE = re.compile(r"; hole at \$([0-9a-fA-F]+): using (\d+) of (\d+) bytes")


def blocks(path):
    d = path.read_bytes()
    pos, out = 0, []
    while pos < len(d):
        if d[pos] == 0:
            ln = d[pos + 1] * 256 + d[pos + 2]
            ad = d[pos + 3] * 256 + d[pos + 4]
            out.append((ad, ln))
            pos += 5 + ln
        else:
            break
    return out


def title_holes(path):
    """(lo, used, capacity) for every load-time hole mktitle actually
    packed into, parsed from its own generated comments. A hole that
    exists but was never reached (the packed title+extra+extra2+music
    stream ran out first) has NO comment here -- title_holes.py's own
    hole list is only available mid-build (/tmp, ephemeral, and shared
    with whatever else is building right now), so it is deliberately
    not read by this script. Absence just means "this region's true
    top equals its flush top", which the block scan already gets right
    on its own -- see region_report()."""
    if not path.exists():
        return []
    out = []
    for m in HOLE_RE.finditer(path.read_text()):
        out.append((int(m.group(1), 16), int(m.group(2)), int(m.group(3))))
    return out


def region_report(REGIONS, used, holes):
    """For every loadable region: the genuinely free byte count right
    now (free_now), and, separately, how much of that was ever real
    resident-code headroom (resident_free) versus title back-fill
    borrowing it (lent). free_now == resident_free - lent.

    holes is keyed by which region's address range each hole's start
    address falls into -- title_holes.py emits exactly one hole per
    region (never two), in ascending address order, so this is a
    straight range lookup, not a positional zip."""
    holes_by_region = {}
    for lo, n, m in holes:
        for start, end, name, ok in REGIONS:
            if ok and start <= lo < end:
                holes_by_region[name] = (lo, n, m)
                break

    report = []
    for start, end, name, ok in REGIONS:
        if not ok:
            continue
        flush_top = used.get(name)
        hole = holes_by_region.get(name)
        if hole is not None:
            lo, n, m = hole
            free_now = m - n
            report.append(dict(
                name=name, top=lo, resident_free=m, lent=n,
                free_now=free_now, backfilled=True,
            ))
        elif flush_top is not None:
            free_now = end - flush_top
            report.append(dict(
                name=name, top=flush_top, resident_free=free_now,
                lent=0, free_now=free_now, backfilled=False,
            ))
        else:
            report.append(dict(
                name=name, top=None, resident_free=end - start,
                lent=0, free_now=end - start, backfilled=False,
            ))
    return report


def main():
    bad = []
    used = {}
    blk = blocks(IMG)
    for ad, ln in blk:
        for start, end, name, ok in REGIONS:
            if ad < end and start < ad + ln:
                lo, hi = max(ad, start), min(ad + ln, end)
                used[name] = max(used.get(name, start), hi)
                if not ok:
                    bad.append(f"{hex(lo)}-{hex(hi - 1)} loads into {name}")

    holes = title_holes(TITLE_LZ)
    report = region_report(REGIONS, used, holes)

    for r in report:
        if r["top"] is None:
            print(f"  (unused)  {r['name']}")
        elif not r["backfilled"]:
            print(f"  {r['free_now']:5d} bytes free  {r['name']} "
                  f"(top {hex(r['top'] - 1)})")
        elif r["free_now"] == 0:
            print(f"  {0:5d} bytes free  {r['name']} (resident top "
                  f"{hex(r['top'] - 1)}) -- full ONLY because mktitle "
                  f"lent all {r['resident_free']} bytes of real spare "
                  f"here to the title screen; resident code does not "
                  f"fill it")
        else:
            print(f"  {r['free_now']:5d} bytes free  {r['name']} "
                  f"(resident top {hex(r['top'] - 1)}) -- "
                  f"{r['lent']} of {r['resident_free']} spare bytes "
                  f"here were lent to the title screen, {r['free_now']} "
                  f"left over")

    by_name = {r["name"]: r for r in report}
    fbA = by_name.get("framebuffer A / $8000 staging block 1")
    fbB = by_name.get("framebuffer B / $8000 staging block 2")
    if fbA and fbB and holes:
        hole_spare_total = sum(r["free_now"] for r in report)
        fbA_spare = fbA["resident_free"]
        fbB_spare = fbB["resident_free"]
        delivery_budget = fbA_spare + fbB_spare + hole_spare_total
        rooms_fit = delivery_budget // MEASURED_PACKED_BYTES_PER_ROOM
        print(f"\nDelivery budget (T0159): framebuffer-A spare "
              f"{fbA_spare} + framebuffer-B spare {fbB_spare} + "
              f"title-hole spare {hole_spare_total} = "
              f"{delivery_budget} packed bytes.")
        print(f"  (Framebuffer spare is counted here AND inside the "
              f"title-hole-spare total above -- they are the SAME "
              f"physical bytes at different moments of boot; see "
              f"NOTES.md T0159. Not a bug, just don't add a third term "
              f"for it.)")
        print(f"  At the last MEASURED cost of "
              f"{MEASURED_PACKED_BYTES_PER_ROOM} packed bytes/room "
              f"(rooms 24+57, NOT a constant of nature -- re-measure "
              f"after the next rooms), that is room for "
              f"~{rooms_fit} more room(s).")
    elif fbA and fbB:
        print("\n(No title_lz.asm found alongside the image -- delivery "
              "budget needs it. Pass it explicitly as the 2nd argument "
              "if it isn't next to the image.)")

    # Cross-block overlap: two blocks can each pass the per-region check
    # above and still stomp each other, since CLOADM applies them in
    # file order and the later one wins for any shared address.
    overlaps = []
    for i, (a1, l1) in enumerate(blk):
        for a2, l2 in blk[i + 1:]:
            lo, hi = max(a1, a2), min(a1 + l1, a2 + l2)
            if lo < hi:
                overlaps.append(
                    f"{hex(lo)}-{hex(hi - 1)}: block {hex(a1)}+{l1} vs "
                    f"{hex(a2)}+{l2} -- the SECOND one wins at load time"
                )

    # T0172: a `rmb` inside the instruction stream reserves space without
    # emitting bytes, so the DECB file SPLITS there and the loader leaves
    # those bytes as it found them -- boot then executes whatever the
    # machine's RAM happened to hold. That shipped for months: MAME's
    # coco2b clears RAM benignly and booted fine, xroar's coco2bus did not
    # and the garbage cleared PIA0 CRA's DDR-select bit, so every key read
    # as held (title froze, no music). Every gap in the load file is
    # therefore listed here, and any gap that is not a KNOWN data buffer
    # fails the build. If a new name shows up, check it is `rmb` for
    # VARIABLES and not a hole in code; if it is code, pad with `fill`.
    KNOWN_DATA_GAPS = {
        "solid_list", "blit_revbuf", "rat_sv_col", "inv", "coin_ram",
    }
    syms = []
    mapf = IMG.with_suffix(".map")
    if mapf.exists():
        for line in mapf.read_text().splitlines():
            m = re.match(r"^Symbol: (\S+) \(.*?\) = ([0-9a-fA-F]+)$", line)
            if m:
                syms.append((int(m.group(2), 16), m.group(1)))
        syms.sort()

    def sym_at(addr):
        name = "?"
        for a, n in syms:
            if a <= addr:
                name = n
            else:
                break
        return name

    gaps = []
    ordered = sorted(blk)
    for (a1, l1), (a2, _l2) in zip(ordered, ordered[1:]):
        if 0 < a2 - (a1 + l1) < 256:
            start = a1 + l1
            gaps.append((start, a2 - start, sym_at(start)))
    unknown_gaps = [g for g in gaps if g[2] not in KNOWN_DATA_GAPS]
    if gaps:
        print("\nLoad-file gaps (unloaded bytes -- must be data, never code):")
        for start, n, name in gaps:
            flag = "" if name in KNOWN_DATA_GAPS else "   <-- NEW, not in KNOWN_DATA_GAPS"
            print(f"  ${start:04x} +{n} at {name}{flag}")

    if bad:
        print("\nOVERRUNS -- these bytes are silently dropped or destroyed at runtime:")
        for b in bad:
            print("  " + b)
    if overlaps:
        print("\nOVERLAPPING BLOCKS -- the earlier block's bytes are silently"
              " overwritten:")
        for o in overlaps:
            print("  " + o)
    if unknown_gaps:
        print("\nUNRECOGNISED LOAD-FILE GAP -- these bytes are NOT written by the"
              " loader. If they are inside code, boot executes uninitialised RAM"
              " (T0172); pad with `fill`, not `rmb`. If they really are variables,"
              " add the symbol to KNOWN_DATA_GAPS.")
        for start, n, name in unknown_gaps:
            print(f"  ${start:04x} +{n} at {name}")
    if bad or overlaps or unknown_gaps:
        return 1
    print("\nEvery loaded byte is in a region that allows loading, and no "
          "two blocks overlap.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
