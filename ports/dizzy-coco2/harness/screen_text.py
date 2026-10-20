#!/usr/bin/env python3
"""Decode raw CoCo alpha-screen bytes (32x16, $0400-$05FF) back to readable
text. Inverse of the ASCII->screen-code mapping (screen_code = ascii & 0x3f,
valid for space through underscore, 0x20-0x5F) used when writing text screen
memory by hand. Bit 6 (0x40) set = inverse video, stripped before decode.

Usage: screen_text.py < raw_screen_bytes    (512 bytes, 32x16)
       screen_text.py FILE
"""
import sys

COLS = 32
ROWS = 16


def decode(data: bytes) -> str:
    lines = []
    for row in range(ROWS):
        chars = []
        for col in range(COLS):
            b = data[row * COLS + col] & 0x3f  # drop inverse-video bit
            # screen code 0x20-0x3F maps directly to ASCII space..? / digits/punct
            # screen code 0x00-0x1F maps to ASCII 0x40-0x5F (@, A-Z, [\]^_)
            ascii_code = b if b >= 0x20 else b + 0x40
            chars.append(chr(ascii_code) if 0x20 <= ascii_code < 0x7f else '.')
        lines.append(''.join(chars).rstrip())
    return '\n'.join(lines)


def main():
    if len(sys.argv) > 1:
        data = open(sys.argv[1], 'rb').read()
    else:
        data = sys.stdin.buffer.read()
    data = data[:COLS * ROWS].ljust(COLS * ROWS, b'\x60')  # pad with space code
    print(decode(data))


if __name__ == "__main__":
    main()
