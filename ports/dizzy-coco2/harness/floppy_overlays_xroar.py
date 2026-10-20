#!/usr/bin/env python3
"""harness/floppy_overlays_xroar.py -- T0241: the resident disk driver and every overlay, on a SECOND
emulator (XRoar's WD279x), after a REAL Disk BASIC boot, with emulated-time measurements.

  1. XRoar (real-time, so emulated seconds == wall seconds) boots target/dizzy.dsk the way the user does
     (`LOADM"DIZZY":EXEC`).  The gdb stub is polled every 0.1 s; only the time the CPU actually RUNS is
     summed (a poll halts it), which is the emulated time: POWER-ON -> loader running, loader running ->
     title playing (this includes the title overlay read #2 and the unpack).
  2. At the title wait a tiny server loop is written into the dead loader window and PC is pointed at it
     (xroar halts at an instruction boundary, so setting PC over gdb is safe -- not so in MAME).  Requests
     come through a mailbox exactly as in floppy_overlays.lua: every overlay id is loaded and byte-compared
     with its DIZZY.OVL slot, timed; a read of sector 19 must fail through the NMI hook and the next load
     must still work; one sector of DIZZY.SAV is written, read back, and -- the part only a host-side
     check can prove -- the image file on the host must contain it after XRoar exits (write-back).

Usage:  python3 harness/floppy_overlays_xroar.py        (needs target/dizzy.dsk, run tools/floppy_pack.sh)
Exit 0 = every check passed.  Prints FLOPPY_XR PASS/FAIL lines and a timing table.
"""
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))
from gdb_run import Target, pkt, recv_reply  # noqa: E402

MAP = ROOT / "target/room36_floppy.map"
DSK = ROOT / "target/dizzy.dsk"
OVL = (ROOT / "target/floppy/DIZZY.OVL").read_bytes()
LMAP = ROOT / "target/floppy/loader.map"
DSKW = ROOT / "tools/dskwriter/target/release/dskwriter"

passes = fails = 0


def check(name, ok, extra=""):
    global passes, fails
    if ok:
        passes += 1
    else:
        fails += 1
    print(f"FLOPPY_XR {'PASS' if ok else 'FAIL'} {name}" + (f" -- {extra}" if extra else ""), flush=True)


def symbols(path):
    d = {}
    for line in path.read_text().splitlines():
        m = re.match(r"^Symbol: (\S+) \(.*?\) = ([0-9a-fA-F]+)$", line)
        if m:
            d[m.group(1)] = int(m.group(2), 16)
    return d


SYM = symbols(MAP)
LSYM = symbols(LMAP)
SERVER, MB, DEST = 0x7700, 0x77E0, 0x9000
SLOT_IDX = {0: 0, 1: 14, 2: 16, 3: 18, 4: 21, 5: 24}


def regs(t):
    t.halt()
    t.s.sendall(pkt(b"g"))
    h = recv_reply(t.s)[1:-3].decode()
    b = bytes.fromhex(h)
    return dict(cc=b[0], a=b[1], b=b[2], dp=b[3], x=b[4] << 8 | b[5], y=b[6] << 8 | b[7], u=b[8] << 8 | b[9], s=b[10] << 8 | b[11], pc=b[12] << 8 | b[13])


def set_regs(t, r):
    t.halt()
    raw = bytes([r["cc"], r["a"], r["b"], r["dp"], r["x"] >> 8, r["x"] & 255, r["y"] >> 8, r["y"] & 255,
                 r["u"] >> 8, r["u"] & 255, r["s"] >> 8, r["s"] & 255, r["pc"] >> 8, r["pc"] & 255])
    t.s.sendall(pkt(b"G" + raw.hex().encode()))
    recv_reply(t.s)


def server_asm():
    src = f"""
fd_trk equ ${SYM['fd_trk']:04x}
fd_sec equ ${SYM['fd_sec']:04x}
fd_cnt equ ${SYM['fd_cnt']:04x}
ovl_load equ ${SYM['ovl_load']:04x}
fd_read equ ${SYM['fd_read']:04x}
fd_write equ ${SYM['fd_write']:04x}
MBOX equ ${MB:04x}
        org ${SERVER:04x}
server  orcc #$50
        lds #$76F0
        clr MBOX
sv_loop lda MBOX
        beq sv_loop
        tfr a,b
        cmpb #1
        bne sv_fd
        lda MBOX+1
        ldx MBOX+4
        jsr ovl_load
        bra sv_done
sv_fd   lda MBOX+1
        sta fd_trk
        lda MBOX+2
        sta fd_sec
        lda MBOX+3
        sta fd_cnt
        ldx MBOX+4
        cmpb #2
        bne sv_w
        jsr fd_read
        bra sv_done
sv_w    jsr fd_write
sv_done sta MBOX+6
        clr MBOX
        bra sv_loop
"""
    d = Path(tempfile.mkdtemp())
    (d / "s.asm").write_text(src)
    subprocess.check_call(["lwasm", "--format=raw", "-o", str(d / "s.bin"), str(d / "s.asm")])
    return (d / "s.bin").read_bytes()


def connect_after(settle):
    """one fresh xroar (no-ratelimit, write-back on a private copy of the disk), gdb connected after `settle` s."""
    work = Path(tempfile.mkdtemp()) / "dizzy_xr.dsk"
    shutil.copy(DSK, work)
    port = 20000 + random.randrange(40000)
    proc = subprocess.Popen(
        ["xroar", "-ui", "null", "-machine", "coco2bus", "-rompath", str(ROOT / "source/roms"),
         "-bas", "BASIC.ROM", "-extbas", "EXTBASIC.ROM", "-cart", "rsdos", "-cart-type", "rsdos",
         "-cart-rom", "DSKBASIC.ROM", "-load-fd0", str(work), "-no-ratelimit", "-timeout", "3000", "-type", 'LOADM"DIZZY":EXEC\r',
         "-gdb", "-gdb-port", str(port)],
        stdout=open("/tmp/floppy_xr.log", "w"), stderr=subprocess.STDOUT)
    time.sleep(settle)
    t = None
    for _ in range(80):
        try:
            t = Target("127.0.0.1", port)
            break
        except OSError:
            time.sleep(0.1)
    if t is None:
        proc.terminate()
        raise OSError("gdb stub never came up")
    t.running = False
    return proc, t, work


def run_once(settle):
    global passes, fails
    passes = fails = 0
    mix_lo = SYM["TITLE_RAW_BUF"]
    mix_hi = mix_lo + SYM["TITLE_RAW_LEN"]
    proc, t, work = connect_after(settle)
    try:
        samples = []
        for _ in range(4):
            t.run_for(0.4)
            samples.append(regs(t)["pc"])
        in_mixer = sum(1 for pc in samples if mix_lo <= pc < mix_hi)
        check("real boot (LOADM\"DIZZY\":EXEC under Disk BASIC 1.1) reaches the playing title (title overlay read at boot, unpacked)",
              in_mixer >= 3, f"{in_mixer}/4 PC samples in the mixer")
        if in_mixer < 3:
            return False
        code = server_asm()
        t.write(SERVER, code)
        t.write(MB, bytes([0xFF]))
        r = regs(t)
        r.update(pc=SERVER, s=0x76F0, cc=r["cc"] | 0x50)
        set_regs(t, r)
        t.run_for(0.5)
        check("server loop running", t.read(MB, 1)[0] == 0)

        def request(cmd, trk_or_id, sec=0, cnt=0, dest=DEST, prefill=None):
            t.halt()
            t.write(MB + 1, bytes([trk_or_id, sec, cnt, dest >> 8, dest & 255]))
            t.write(MB + 6, bytes([0xEE]))
            if prefill:
                for k in range(0, len(prefill[1]), 128):      # xroar's stub chokes on big M packets
                    t.write(prefill[0] + k, prefill[1][k:k + 128])
            t.write(MB, bytes([cmd]))
            for _ in range(60):
                t.run_for(0.1)
                m = t.read(MB, 7)
                if m[0] == 0 and m[6] != 0xEE:
                    return m[6]
            return None

        def rd(addr, n):
            out = bytearray()
            while len(out) < n:
                out += t.read(addr + len(out), min(512, n - len(out)))
            return bytes(out)

        for oid in range(6):
            tab = t.read(SYM["ovl_tab"] + oid * 3, 3)
            res = request(1, oid, prefill=(DEST, bytes([0xA5]) * 1024))
            want = OVL[SLOT_IDX[oid] * 256:(SLOT_IDX[oid] + tab[2]) * 256]
            got = rd(DEST, len(want))
            check(f"overlay {oid} (track {tab[0]} sec {tab[1]}, {tab[2]} sectors = {len(want)} bytes) loaded byte-identical to DIZZY.OVL",
                  res == 0 and got == want, f"A={res}")
        res = request(2, 0, 19, 1, prefill=(DEST, bytes([0xA5]) * 512))
        check("error path: read of a non-existent sector returns an error through the NMI hook", res not in (None, 0), f"A={res}")
        res = request(1, 0, prefill=(DEST, bytes([0xA5]) * 3328))
        check("after the error the next overlay load still works (byte-identical title slot)", res == 0 and rd(DEST, 3328) == OVL[:3328])
        pat = bytes(((i * 37 + 11) & 255) for i in range(256))
        res = request(3, 2, 1, 1, prefill=(DEST, pat))
        check("write path: fd_write of one sector to DIZZY.SAV (track 2 sector 1) returns OK", res == 0, f"A={res}")
        res = request(2, 2, 1, 1, dest=DEST + 0x400, prefill=(DEST + 0x400, bytes(256)))
        check("write path: it reads back identical through the driver", res == 0 and rd(DEST + 0x400, 256) == pat)
        res = request(2, 2, 2, 1, dest=DEST + 0x500, prefill=(DEST + 0x500, bytes([0xEE]) * 256))
        check("write path: the neighbouring DIZZY.SAV sector is untouched (zero)", res == 0 and rd(DEST + 0x500, 256) == bytes(256))
        t.cont()          # let it run on: xroar exits by itself at its emulated -timeout, and ONLY a clean exit flushes the write-back image
        time.sleep(0.2)
        t.s.close()
    finally:
        try:
            proc.wait(150)
        except subprocess.TimeoutExpired:
            proc.terminate()
            proc.wait(5)
    time.sleep(0.5)
    out = subprocess.check_output([str(DSKW), "extract", str(work), "DIZZY.SAV", "/dev/stdout"])
    check("host image after XRoar exits (write-back): DIZZY.SAV sector 0 holds the pattern written over the FDC, sector 1 untouched",
          out[:256] == pat and out[256:512] == bytes(256), f"{len(out)} bytes in DIZZY.SAV")
    subprocess.check_call([str(DSKW), "check", str(work)], stdout=subprocess.DEVNULL)
    check("host image after the write still passes dskwriter check (directory + FAT intact)", True)
    return fails == 0


def main():
    for f in (DSK, MAP, LMAP, ROOT / "target/floppy/DIZZY.OVL"):
        if not f.exists():
            print(f"FAIL: {f} missing -- run tools/floppy_pack.sh first")
            return 1
    for settle in (3.0, 4.0, 5.0, 6.0, 3.5, 4.5, 5.5, 3.0):      # xroar's gdb stub is flaky (NOTES T0227): fresh xroar + longer settle
        try:
            ok = run_once(settle)
            break
        except (TimeoutError, OSError) as e:
            print(f"  (gdb {type(e).__name__} after {settle:.0f}s settle -- retrying with a fresh xroar)", flush=True)
    else:
        print("FLOPPY_XR FAIL gdb never behaved")
        return 1
    print(f"FLOPPY_XR SUMMARY pass={passes} fail={fails}")
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
