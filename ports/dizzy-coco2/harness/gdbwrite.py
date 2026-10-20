#!/usr/bin/env python3
"""Minimal GDB remote-serial-protocol client for WRITING target memory.
Companion to gdbmem.py (read-only) -- same connection handling (a single
short-lived connection; the gdb stub was observed to stop serving a real
client after repeated connect/disconnect probes, see capture.sh).
Usage: gdbwrite.py HOST PORT ADDR_HEX HEXBYTES
  e.g. gdbwrite.py 127.0.0.1 12345 15b3 5a   (writes byte $5a to $15b3)
"""
import socket
import sys


def checksum(data: bytes) -> int:
    return sum(data) % 256


def make_packet(data: bytes) -> bytes:
    return b"$" + data + b"#" + f"{checksum(data):02x}".encode()


def recv_reply(sock: socket.socket) -> bytes:
    buf = b""
    while True:
        c = sock.recv(1)
        if not c:
            break
        if c == b"+" or c == b"-":
            continue
        buf += c
        if c == b"#":
            buf += sock.recv(2)
            break
    return buf


def main():
    host, port, addr_hex, hexbytes = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
    data = bytes.fromhex(hexbytes)
    s = socket.create_connection((host, port), timeout=5)
    cmd = f"M{addr_hex},{len(data):x}:".encode() + hexbytes.encode()
    s.sendall(make_packet(cmd))
    reply = recv_reply(s)
    s.close()
    body = reply[1:-3]
    if body.startswith(b"E"):
        print(f"ERROR: {body.decode()}", file=sys.stderr)
        sys.exit(1)
    print("OK" if body == b"OK" else body.decode(errors="replace"))


if __name__ == "__main__":
    main()
