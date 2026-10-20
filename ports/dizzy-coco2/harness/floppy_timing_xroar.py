#!/usr/bin/env python3
"""harness/floppy_timing_xroar.py -- T0241: EMULATED-SECOND load times on XRoar, exact, with no polling.

How: XRoar can record the cassette output (-tape-write FILE.wav) and the sample clock of that file IS
emulated time.  After a real Disk BASIC boot (LOADM"DIZZY":EXEC) a timing server is written into RAM over
gdb (one connect, no polling), the CPU is pointed at it and released.  The server turns the tape motor on,
emits a marker burst on the DAC, runs one disk operation, emits another marker, and so on.  XRoar quits
by itself (-timeout-motoroff) after the final motor-off, which also flushes the .wav; the gaps between
markers are the operation times.

Every operation is the shipped driver: ovl_load for the overlays, fd_read/fd_write for the rest.  Each
call starts with the motor off, so every time here INCLUDES the 0.59 s spin-up (FD_SPINUP loop) -- that
is what a player waits.

Usage: python3 harness/floppy_timing_xroar.py [--loader-marks]
  (--loader-marks additionally times the boot loader: see harness/floppy_timing_loader.sh)
"""
import random
import re
import subprocess
import sys
import tempfile
import time
import wave
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))
from gdb_run import Target, pkt, recv_reply  # noqa: E402

MAP = ROOT / "target/room36_floppy.map"
DSK = ROOT / "target/dizzy.dsk"


def symbols(path):
    d = {}
    for line in path.read_text().splitlines():
        m = re.match(r"^Symbol: (\S+) \(.*?\) = ([0-9a-fA-F]+)$", line)
        if m:
            d[m.group(1)] = int(m.group(2), 16)
    return d


SYM = symbols(MAP)
SERVER, DEST = 0x7600, 0x9000

# (label, kind, args)
OPS = [
    ("title overlay (13 sectors, 3328 B) -> TITLE_LZ_BUF [boot + every game-over/win replay]", "ovl", (0,)),
    ("heart demo overlay (2 sectors)", "ovl", (1,)),
    ("heart demo overlay again (motor was off, head already on track 0)", "ovl", (1,)),
    ("quick-save overlay (OVL_SAVE_A, 3 sectors)", "ovl", (3,)),
    ("quick SAVE disk write: 4 sectors of DIZZY.SAV (one command each)", "wr", (2, 1, 4)),
    ("quick LOAD disk read: the same 4 sectors in one command", "rd", (2, 1, 4)),
    ("one whole track in ONE command (track 3, 18 sectors = 4608 B)", "rd", (3, 1, 18)),
    ("one sector (track 3 sector 1)", "rd", (3, 1, 1)),
    ("one sector after a 20-track seek (track 23)", "rd", (23, 1, 1)),
    ("save slot: write one sector (DIZZY.SAV track 2 sector 1) incl. spin-up", "wr", (2, 1, 1)),
    ("save slot: read the whole 18-sector slot back (track 2)", "rd", (2, 1, 18)),
]


import os
OPS = OPS[:int(os.environ.get("NOPS", len(OPS)))]


def server_asm():
    lines = [f"""
fd_trk equ ${SYM['fd_trk']:04x}
fd_sec equ ${SYM['fd_sec']:04x}
fd_cnt equ ${SYM['fd_cnt']:04x}
ovl_load equ ${SYM['ovl_load']:04x}
fd_read equ ${SYM['fd_read']:04x}
fd_write equ ${SYM['fd_write']:04x}
DEST equ ${DEST:04x}
        org ${SERVER:04x}
server  orcc #$50
        lds #$75F0
        lda $FF21
        ora #8                  ; tape motor on
        sta $FF21
        lbsr mark
"""]
    for i, (label, kind, args) in enumerate(OPS):
        if kind == "ovl":
            lines.append(f"        lda #{args[0]}\n        ldx #DEST\n        jsr ovl_load\n")
        else:
            lines.append(f"        lda #{args[0]}\n        sta fd_trk\n        lda #{args[1]}\n        sta fd_sec\n        lda #{args[2]}\n        sta fd_cnt\n        ldx #DEST\n        jsr {'fd_read' if kind == 'rd' else 'fd_write'}\n")
        lines.append("        lbsr mark\n")
    lines.append("""        lda $FF21
        anda #$F7               ; tape motor off -> xroar quits (-timeout-motoroff)
        sta $FF21
hang    bra hang
mark    ldb #6
mk1     lda #$FC
        sta $FF20
        lbsr dly
        clra
        sta $FF20
        lbsr dly
        decb
        bne mk1
        rts
dly     ldx #200
dl1     leax -1,x
        bne dl1
        rts
""")
    d = Path(tempfile.mkdtemp())
    (d / "s.asm").write_text("".join(lines))
    subprocess.check_call(["lwasm", "--format=raw", "-o", str(d / "s.bin"), str(d / "s.asm")])
    return (d / "s.bin").read_bytes()


def bursts(path):
    w = wave.open(str(path), "rb")
    n, rate, width = w.getnframes(), w.getframerate(), w.getsampwidth()
    raw = w.readframes(n)
    ch = w.getnchannels()
    import struct
    fmt = {1: "B", 2: "h"}[width]
    vals = struct.unpack("<" + fmt * (n * ch), raw)[::ch]
    mid = (max(vals) + min(vals)) / 2
    edges = [i for i in range(1, len(vals)) if (vals[i - 1] > mid) != (vals[i] > mid)]
    groups = []
    for e in edges:
        if groups and e - groups[-1][1] < 0.05 * rate:
            groups[-1][1] = e
        else:
            groups.append([e, e])
    return [(a / rate, b / rate) for a, b in groups], rate


def main():
    wav = Path(tempfile.mkdtemp()) / "t.wav"
    port = 20000 + random.randrange(40000)
    code = server_asm()
    assert len(code) < 0x1F0, f"timing server {len(code)} B does not fit the dead loader window"
    for settle in (3.0, 4.0, 5.0):
        proc = subprocess.Popen(
            ["xroar", "-ui", "null", "-machine", "coco2bus", "-rompath", str(ROOT / "source/roms"),
             "-bas", "BASIC.ROM", "-extbas", "EXTBASIC.ROM", "-cart", "rsdos", "-cart-type", "rsdos",
             "-cart-rom", "DSKBASIC.ROM", "-load-fd0", str(DSK), "-no-disk-write-back", "-no-ratelimit",
             "-tape-write", str(wav), "-tape-ao-rate", "44100", "-timeout-motoroff", "1", "-timeout", "3000",
             "-type", 'LOADM"DIZZY":EXEC\r', "-gdb", "-gdb-port", str(port)],
            stdout=open("/tmp/floppy_timing.log", "w"), stderr=subprocess.STDOUT)
        time.sleep(settle)
        try:
            t = None
            for _ in range(80):
                try:
                    t = Target("127.0.0.1", port)
                    break
                except OSError:
                    time.sleep(0.1)
            t.running = False
            t.halt()
            t.write(SERVER, code)
            t.s.sendall(pkt(b"g"))
            h = recv_reply(t.s)[1:-3].decode()
            b = bytearray(bytes.fromhex(h))
            b[0] |= 0x50
            b[10:12] = (0x75F0).to_bytes(2, "big")
            b[12:14] = SERVER.to_bytes(2, "big")
            t.s.sendall(pkt(b"G" + bytes(b).hex().encode()))
            recv_reply(t.s)
            t.cont()
            time.sleep(0.2)
            t.s.close()
            break
        except (TimeoutError, OSError, BrokenPipeError) as e:
            print(f"  (gdb {type(e).__name__} at settle {settle}: retrying)")
            proc.terminate()
            proc.wait(5)
            wav = Path(tempfile.mkdtemp()) / "t.wav"
    else:
        print("FAIL: gdb never behaved")
        return 1
    proc.wait(200)
    time.sleep(0.3)
    bs, rate = bursts(wav)
    need = len(OPS) + 1
    if len(bs) != need:
        print(f"FAIL: expected {need} marker bursts in the tape recording, found {len(bs)}: {bs[:12]}")
        return 1
    print("FLOPPY_TIMING XRoar, emulated seconds (tape-recording clock); each includes the motor spin-up:")
    for i, (label, kind, args) in enumerate(OPS):
        dt = bs[i + 1][0] - bs[i][1]
        print(f"  {dt:6.2f} s  {label}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
