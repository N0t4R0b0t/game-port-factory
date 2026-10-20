#!/usr/bin/env python3
"""Verify every generated sprite byte matches a straight decode of the
Spectrum's own FRAMES.DAT -- i.e. that no lossy art transform is active.

Exists because this port spent two sessions inventing art transforms
(dither retuning, morphological closing, outline extraction) to compensate
for a video-mode bug (NOTES.md T0028/T0029). With the mode fixed the
correct pipeline is "change nothing", and this is the check that says so
out loud instead of trusting a flag list.

Run from the port root: tools/verify_verbatim.py
Exit 0 = every sprite is byte-identical to the original art.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FRAMES = ROOT / "research/D3-prior-art/original_source/FRAMES.DAT"


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
    """The reference decode: exactly what the Spectrum art is."""
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


def parse_asm(path):
    """label -> (w, h, bpr, bytes) for every sprite in a generated .asm."""
    txt = path.read_text()
    w = {k: int(v) for k, v in re.findall(r"^(\S+)_w\tfcb (\d+)", txt, re.M)}
    h = {k: int(v) for k, v in re.findall(r"^(\S+)_h\tfcb (\d+)", txt, re.M)}
    bpr = {k: int(v) for k, v in re.findall(r"^(\S+)_bpr\tfcb (\d+)", txt, re.M)}
    data = {k: bytes(int(x[1:], 16) for x in v.split(","))
            for k, v in re.findall(r"^(\S+)\t\tfcb ([^\n]+)", txt, re.M)}
    return {k: (w[k], h[k], bpr[k], data[k]) for k in w if k in h and k in bpr and k in data}


def artifact_mask(width, height, bpr, data, even_columns):
    """Ink kept only on even (orange) or odd (blue) screen columns."""
    out = bytearray(len(data))
    for r in range(height):
        for c in range(width):
            if (c % 2 == 0) == even_columns and (data[r * bpr + c // 8] >> (7 - (c % 8))) & 1:
                out[r * bpr + c // 8] |= 1 << (7 - (c % 8))
    return bytes(out)


def mirror(width, height, bpr, data):
    out = bytearray(len(data))
    for r in range(height):
        for c in range(width):
            if (data[r * bpr + c // 8] >> (7 - (c % 8))) & 1:
                d = width - 1 - c
                out[r * bpr + d // 8] |= 1 << (7 - (d % 8))
    return bytes(out)


def main():
    tbl, defs = load_frames()
    checked = failed = skipped = 0
    coloured = []
    overridden = []
    # T0077: glyph slots deliberately replaced with a hand-drawn icon, not
    # extracted from FRAMES.DAT at all (see roompack's --glyph-override and
    # regen_art.sh's own comment on it). No transform of the original to
    # verify against -- these are reported separately, not silently folded
    # into "skipped: not frame-derived", so a genuine corruption elsewhere
    # in the font still fails loudly.
    CUSTOM_GLYPHS = {"glyph_81"}

    for path in sorted((ROOT / "target").glob("*_data.asm")):
        for label, (w, h, bpr, data) in sorted(parse_asm(path).items()):
            # flame_N: frame 115, index = tone + 2*mirrored (tone variants
            # are identical once --shade is off). water_N: frames 92+N.
            fm = re.match(r"^r\d+_flame_([0-3])$", label)
            wm = re.match(r"^r\d+_water_([0-3])$", label)
            # T0035 follow-up: shared_sprites_data.asm emits plain,
            # deduplicated sprites with NO room prefix (spr_134, not
            # r36_spr_134) -- same frame-number check either way.
            m = re.match(r"^(?:r\d+_spr|spr|aspr|glyph)_(\d+)", label)
            if fm:
                frame, mirrored = 115, int(fm.group(1)) >= 2
            elif wm:
                frame, mirrored = 92 + int(wm.group(1)), False
            elif m:
                # Two different mirrored-variant suffixes, both real:
                # `_mirror` is an ACTOR variant asked for by name
                # (--mirror-frames, e.g. the rat's facing), `_m` is a
                # ROOM-PLACEMENT variant emitted because that placement's
                # colour byte has bit 7 set -- the original's own
                # `frmreverse` flag (T0045-T0048). Both must be checked
                # against the MIRROR of the source bitmap, not the raw
                # one, or every correctly-flipped sprite reads as
                # corrupted.
                frame = int(m.group(1))
                mirrored = label.endswith("_mirror") or label.endswith("_m")
            else:
                skipped += 1
                continue
            if label in CUSTOM_GLYPHS:
                overridden.append(label)
                continue
            ref = decode(tbl, defs, frame)
            if ref is None:
                skipped += 1
                continue
            rw, rh, rdata = ref
            expect = mirror(rw, rh, (rw + 7) // 8, rdata) if mirrored else rdata
            checked += 1
            # The animated flame/water tiles may be deliberately masked to
            # alternate screen columns for NTSC artifact colour (NOTES.md
            # T0033-note). Accept exactly those two transforms of the
            # original -- and nothing else, so a corrupted tile still fails.
            # Frames deliberately artifact-coloured. MUST be kept in sync
            # with tools/regen_art.sh -- listing a frame here only says "a
            # column mask is allowed", the mask itself is still verified
            # exactly, so a corrupted sprite fails either way.
            COLOURED_ACTORS = {"aspr_17", "aspr_20", "aspr_19"}
            may_colour = bool(fm or wm) or label.split("_mirror")[0] in COLOURED_ACTORS
            if may_colour and data != expect:
                rbpr = (rw + 7) // 8
                for even, hue in ((True, "orange"), (False, "blue")):
                    if data == artifact_mask(rw, rh, rbpr, expect, even):
                        coloured.append(f"{label} ({hue})")
                        expect = data
                        break
            if (w, h, bpr, data) != (rw, rh, (rw + 7) // 8, expect):
                failed += 1
                if data != expect and (w, h) == (rw, rh):
                    diff = sum(bin(a ^ b).count("1") for a, b in zip(data, expect))
                    print(f"FAIL {path.name}:{label} frame {frame}: {diff} bits differ from original")
                else:
                    print(f"FAIL {path.name}:{label} frame {frame}: "
                          f"got {w}x{h} bpr={bpr}, original {rw}x{rh} bpr={(rw + 7) // 8}")

    print(f"\n{checked} sprites checked against FRAMES.DAT, {failed} differ "
          f"({skipped} labels skipped: not frame-derived)")
    if coloured:
        print(f"{len(coloured)} artifact-coloured tiles (deliberate, verified as an exact "
              f"column mask of the original): {', '.join(coloured[:4])}"
              + (" ..." if len(coloured) > 4 else ""))
    if overridden:
        print(f"{len(overridden)} glyph(s) deliberately hand-drawn, not from FRAMES.DAT "
              f"(--glyph-override): {', '.join(overridden)}")
    if failed:
        print("Art is NOT verbatim -- a lossy transform is active (see tools/regen_art.sh)")
    else:
        print("All art is byte-identical to the Spectrum original.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
