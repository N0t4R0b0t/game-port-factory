#!/usr/bin/env python3
"""Convert the real Spectrum title screen (a 256x192 PNG) to a linear
PMODE4 1bpp image for tools/mktitle.

WHY A PNG AND NOT A .SCR: the title screen is NOT in the original source
as a bitmap. DIZ3SPEC.SCR is the tape LOADING screen -- a different
picture, and shipping it as the title was wrong (T0096, caught by a
playtest). The other .SCR files are 8192-byte Amstrad screens. The game
draws its title from sprites at runtime, so the only sources are a
capture of the running original or the 256x192 grab already vendored at
research/D3-prior-art/info/dizzy3_title.png.

THRESHOLD 64, chosen by rendering the alternatives and looking:

    128  loses "STARRING THE YOLKFOLK" and the DIZZY-heart-DAISY heart
     96  still loses both (red text luminance is ~76)
     64  keeps them; the tree gets a little noisy, which is fine
  bayer  dithers the flat areas and makes the lettering mushy

Red is a large part of this design and any threshold above ~76 throws it
away, so do not raise it without re-rendering the result.
"""
import sys
from PIL import Image

THRESHOLD = 64


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: title_image.py <title.png> <out.bin>")
    im = Image.open(sys.argv[1]).convert("RGB")
    if im.size != (256, 192):
        sys.exit(f"expected a 256x192 image, got {im.size[0]}x{im.size[1]}")
    out = bytearray(6144)
    for y in range(192):
        for x in range(256):
            r, g, b = im.getpixel((x, y))
            if 0.299 * r + 0.587 * g + 0.114 * b >= THRESHOLD:
                out[y * 32 + x // 8] |= 1 << (7 - (x % 8))
    open(sys.argv[2], "wb").write(bytes(out))
    ink = sum(bin(v).count("1") for v in out)
    print(f"   title image: 256x192, {ink * 100 // (6144 * 8)}% ink, threshold {THRESHOLD}")


if __name__ == "__main__":
    main()
