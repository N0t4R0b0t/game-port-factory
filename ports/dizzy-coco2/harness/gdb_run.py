#!/usr/bin/env python3
"""GDB-remote helper that actually keeps the CPU running. xroar's gdb
stub halts the target the moment a client connects/issues its first
command (confirmed: `?` replies S02 immediately, and memory reads never
advance a heartbeat counter no matter how long you sleep afterward) --
every earlier "poke state, sleep, read back" test in this session was
silently reading a frozen snapshot, not observing real execution.

Correct pattern: send 'c' (continue) to resume, then to safely read or
write memory again, send a raw interrupt byte (0x03) to re-halt, do the
access, 'c' again to resume. This module provides that as read/write
helpers plus run_for(seconds) so a caller can hold a position across
real elapsed execution time and then inspect state truthfully.
"""
import socket, time


def checksum(d):
    return sum(d) % 256


def pkt(d):
    return b"$" + d + b"#" + f"{checksum(d):02x}".encode()


def recv_reply(s):
    buf = b""
    while True:
        c = s.recv(1)
        if not c:
            break
        if c in (b"+", b"-"):
            continue
        buf += c
        if c == b"#":
            buf += s.recv(2)
            break
    return buf


class Target:
    def __init__(self, host, port):
        self.s = socket.create_connection((host, port), timeout=5)
        self.running = False

    def cont(self):
        self.s.sendall(pkt(b"c"))
        self.running = True

    def halt(self):
        if not self.running:
            return
        self.s.sendall(b"\x03")
        recv_reply(self.s)  # stop reply (S05 etc)
        self.running = False

    def read(self, addr, n):
        self.halt()
        self.s.sendall(pkt(f"m{addr:x},{n:x}".encode()))
        body = recv_reply(self.s)[1:-3]
        return bytes.fromhex(body.decode())

    def write(self, addr, data):
        self.halt()
        hexb = data.hex()
        self.s.sendall(pkt(f"M{addr:x},{len(data):x}:{hexb}".encode()))
        recv_reply(self.s)

    def run_for(self, seconds):
        self.cont()
        time.sleep(seconds)
        self.halt()

    def close(self):
        try:
            self.halt()
        finally:
            self.s.close()
