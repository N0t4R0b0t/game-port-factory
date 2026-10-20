#!/usr/bin/env python3
"""Decode raw PMODE4 framebuffer bytes (256x192, 1bpp, MSB-first, 32 bytes/row)
to a PNG. Inverse of what capture.sh's gdbmem.py pulls out of a running
xroar instance's screen memory.

Usage: pmode4_to_png.py < raw_6144_bytes > out.png
       pmode4_to_png.py FILE out.png
"""
import sys
from PIL import Image

W, H = 256, 192
ROW_BYTES = 32


def decode(data: bytes) -> Image.Image:
    img = Image.new("L", (W, H), 255)
    px = img.load()
    for y in range(H):
        for byte_i in range(ROW_BYTES):
            b = data[y * ROW_BYTES + byte_i]
            for bit in range(8):
                x = byte_i * 8 + bit
                on = (b >> (7 - bit)) & 1
                px[x, y] = 0 if on else 255
    return img


def main():
    if len(sys.argv) > 2:
        data = open(sys.argv[1], 'rb').read()
        out = sys.argv[2]
    elif len(sys.argv) > 1:
        data = open(sys.argv[1], 'rb').read()
        out = "pmode4.png"
    else:
        data = sys.stdin.buffer.read()
        out = "pmode4.png"
    data = data[:W * H // 8].ljust(W * H // 8, b'\x00')
    decode(data).save(out)
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
