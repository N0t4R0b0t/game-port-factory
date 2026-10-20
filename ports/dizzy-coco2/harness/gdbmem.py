#!/usr/bin/env python3
"""Minimal GDB remote-serial-protocol client for reading target memory.
Used by the differential harness to pull screen/state RAM out of a running
xroar instance headlessly (no screenshot, no snapshot-format parsing needed).
Usage: gdbmem.py HOST PORT ADDR_HEX LEN_DEC
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
    host, port, addr_hex, length = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
    s = socket.create_connection((host, port), timeout=5)
    # m<addr>,<length> — read length bytes starting at addr, both hex
    cmd = f"m{addr_hex},{length:x}".encode()
    s.sendall(make_packet(cmd))
    reply = recv_reply(s)
    # strip leading '$' and trailing '#xx'
    body = reply[1:-3]
    if body.startswith(b"E"):
        print(f"ERROR: {body.decode()}", file=sys.stderr)
        sys.exit(1)
    data = bytes.fromhex(body.decode())
    sys.stdout.buffer.write(data)
    s.close()


if __name__ == "__main__":
    main()
