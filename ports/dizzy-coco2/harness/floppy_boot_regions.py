#!/usr/bin/env python3
"""harness/floppy_boot_regions.py -- T0241: boot target/dizzy.dsk THE WAY THE USER DOES and diff RAM.

XRoar with Disk Extended BASIC 1.1 (source/roms/DSKBASIC.ROM) and the disk in drive 0, the
keyboard types   LOADM"DIZZY":EXEC   -- Disk BASIC reads DIZZY.BIN (the loader), the loader
streams DIZZY.DAT with the private WD1793 driver, the game's `start` runs, show_title loads the
title OVERLAY from DIZZY.OVL (disk read #2, a different file, through the resident driver) and
the title plays.  Then, over xroar's GDB stub:

  1. boot sanity: PIA0 CRA DDR-select bit set; the title is PLAYING (PC samples inside the mixer
     blob TITLE_RAW_BUF..+TITLE_RAW_LEN) -- proves the whole chain incl. the overlay unpack;
  2. EVERY segment of target/room36_floppy.bin is byte-identical in RAM, except the windows boot
     legitimately rewrites (framebuffers, boot variables) -- catches load-order/spill bugs;
  3. nibswap table (built by start:) correct;
  4. the loader's spill guard in practice: the bytes between segments are not asserted (they are
     whatever the padding wrote) but the loader window ($7600-$77FF) is inside FB B, rewritten.
  5. (--overlay-check) the title overlay bytes: TITLE_LZ_BUF holds the first TITLE_RESIDENT_LEN
     bytes of DIZZY.OVL's title slot until the transpose overwrites it -- NOT checkable after the
     title is up, so this is verified by harness/floppy_overlays.lua (MAME) instead.

Usage: python3 harness/floppy_boot_regions.py [--dsk PATH] [--settle SECONDS]
Exit 0 = PASS.  Run tools/floppy_pack.sh first.
"""
import random
import re
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))
from gdb_run import Target, pkt, recv_reply  # noqa: E402

BIN = ROOT / "target/room36_floppy.bin"
MAP = ROOT / "target/room36_floppy.map"


def arg(name, default):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default


DSK = Path(arg("--dsk", str(ROOT / "target/dizzy.dsk")))
SETTLE = float(arg("--settle", "0"))


def symbols(path):
    syms = {}
    for line in path.read_text().splitlines():
        m = re.match(r"^Symbol: (\S+) \(.*?\) = ([0-9a-fA-F]+)$", line)
        if m:
            syms[m.group(1)] = int(m.group(2), 16)
    return syms


def decb_segments(path):
    d = path.read_bytes()
    pos, segs = 0, []
    while pos < len(d):
        t = d[pos]
        if t == 0:
            ln = d[pos + 1] * 256 + d[pos + 2]
            ad = d[pos + 3] * 256 + d[pos + 4]
            segs.append((ad, d[pos + 5:pos + 5 + ln]))
            pos += 5 + ln
        elif t == 0xFF:
            break
        else:
            sys.exit(f"unknown DECB block type {t:#x}")
    return segs


def xroar_cmd(port, dsk, extra=()):
    return ["xroar", "-ui", "null", "-machine", "coco2bus",
            "-rompath", str(ROOT / "source/roms"),
            "-bas", "BASIC.ROM", "-extbas", "EXTBASIC.ROM",
            "-cart", "rsdos", "-cart-type", "rsdos", "-cart-rom", "DSKBASIC.ROM",
            "-load-fd0", str(dsk), "-no-disk-write-back",
            *extra,
            "-type", 'LOADM"DIZZY":EXEC\r',
            "-gdb", "-gdb-port", str(port)]


def boot(want_mem, mix_lo, mix_hi, tag, settle):
    last = None
    for s in ([settle] if settle else [8.0, 14.0, 22.0]):
        try:
            return _boot_once(want_mem, mix_lo, mix_hi, tag, s)
        except (TimeoutError, OSError) as e:
            last = e
            print(f"  (boot {tag}: gdb {type(e).__name__} after {s:.0f}s settle -- retrying with a fresh xroar)")
    raise last


def _boot_once(want_mem, mix_lo, mix_hi, tag, settle):
    port = 20000 + random.randrange(40000)
    log = open(f"/tmp/dizzy-coco2-floppy-regions-{tag}.log", "w")
    proc = subprocess.Popen(xroar_cmd(port, DSK, ["-no-ratelimit"]), stdout=log, stderr=subprocess.STDOUT)
    try:
        time.sleep(settle)
        tgt = None
        for _ in range(80):
            try:
                tgt = Target("127.0.0.1", port)
                break
            except OSError:
                time.sleep(0.1)
        if tgt is None:
            return None, ["xroar's gdb stub never came up"]
        tgt.running = False
        fails = []
        try:
            samples = []
            for _ in range(5):
                tgt.run_for(0.5)
                tgt.s.sendall(pkt(b"g"))
                pc = int(recv_reply(tgt.s)[1:-3].decode()[-4:], 16)
                cra = tgt.read(0xFF01, 1)[0]
                samples.append((pc, cra))
            if not all(c & 0x04 for _, c in samples):
                fails.append("PIA0 CRA DDR-select bit clear: " + " ".join(f"${c:02x}" for _, c in samples))
            in_mixer = sum(1 for pc, _ in samples if mix_lo <= pc < mix_hi)
            if in_mixer < len(samples) - 1:
                fails.append(f"title is NOT playing: only {in_mixer}/{len(samples)} PC samples inside the mixer "
                             f"${mix_lo:04x}-${mix_hi:04x} (PCs: {' '.join(f'${pc:04x}' for pc, _ in samples)})")
            mem = {}
            for addr, n in want_mem:
                out = bytearray()
                a = addr
                while a < addr + n:
                    k = min(512, addr + n - a)
                    out += tgt.read(a, k)
                    a += k
                mem[addr] = bytes(out)
            return mem, fails, in_mixer, len(samples)
        finally:
            tgt.close()
    finally:
        proc.terminate()
        log.close()


def main():
    for f in (DSK, BIN, MAP):
        if not f.exists():
            print(f"FAIL: {f} missing -- run tools/floppy_pack.sh first")
            return 1
    sym = symbols(MAP)
    mix_lo = sym["TITLE_RAW_BUF"]
    mix_hi = mix_lo + sym["TITLE_RAW_LEN"]
    segs = decb_segments(BIN)
    fails = []
    rewritten = [
        ("framebuffer A $4000-$57FF", 0x4000, 0x5800, "staged block A relocated, then the title image"),
        ("framebuffer B $6000-$77FF (incl. the loader)", 0x6000, 0x7800, "staged block B relocated, then title scratch"),
        ("boot variables ti_len..lz_state", sym["ti_len"], sym["lz_state"] + 1, "written by the title unpack"),
        ("disk driver state fd_trk..ovl_try", sym["fd_trk"], sym["fd_nmisv"] + 3, "the title overlay load (read #2) moves the cursor"),
        ("ovl_try", sym["ovl_try"], sym["ovl_try"] + 1, "retry counter, the overlay load counts down"),
    ]
    want = [(s, len(d)) for s, d in segs]
    nib = sym["nibswap"]
    want.append((nib, 256))
    print(f"real floppy boot of {DSK.name}: LOADM\"DIZZY\":EXEC under Disk BASIC 1.1, {len(segs)} DECB segments")
    res = boot(want, mix_lo, mix_hi, "main", SETTLE)
    if res[0] is None:
        print("FAIL: " + res[1][0])
        return 1
    mem, bfails, in_mixer, nsamp = res
    fails += bfails
    print(f"boot: title playing: {in_mixer}/{nsamp} PC samples in mixer ${mix_lo:04x}-${mix_hi:04x}")

    raw = BIN.read_bytes()
    exec_addr = raw[-2] * 256 + raw[-1]
    print(f"EXEC address of the game image: ${exec_addr:04x} (start = ${sym['start']:04x})")
    if exec_addr != sym["start"]:
        fails.append("DECB exec address is not start")

    want_nib = bytes((((s & 15) << 4) | (s >> 4)) for s in range(256))
    got_nib = bytes(mem[nib][(i + 128) & 255] for i in range(256))
    if got_nib != want_nib:
        fails.append(f"nibswap table wrong after boot: {sum(1 for i in range(256) if got_nib[i] != want_nib[i])} of 256 entries differ")
    else:
        print(f"nibswap ${nib:04x}-${nib + 256:04x}: all 256 entries correct")

    exempt_total = checked = 0
    for ad, data in segs:
        live = mem[ad]
        bad_first, bad_n, ex_n = None, 0, 0
        for i in range(len(data)):
            if live[i] == data[i]:
                continue
            a = ad + i
            if any(lo <= a < hi for _, lo, hi, _ in rewritten):
                ex_n += 1
                continue
            bad_n += 1
            if bad_first is None:
                bad_first = (a, live[i], data[i])
        checked += len(data)
        exempt_total += ex_n
        if bad_n:
            a, got, exp = bad_first
            fails.append(f"segment ${ad:04x}-${ad + len(data):04x}: {bad_n} byte(s) differ after boot, "
                         f"first at ${a:04x} got ${got:02x} expected ${exp:02x}")
    print(f"segments: {checked} bytes of {len(segs)} DECB segments compared; {exempt_total} differ only inside "
          f"boot-rewritten windows; "
          + ("the rest are byte-identical" if not [f for f in fails if f.startswith('segment')] else "MISMATCH (below)"))
    # explicit lines for the interesting regions
    def same_outside_rewritten(a, data):
        return all(mem[a][i] == data[i] or any(lo <= a + i < hi for _, lo, hi, _ in rewritten) for i in range(len(data)))
    for name in ("tape_room_staged_start", "tape_c_raw_start", "tape_d_raw_start", "tape_low_slot_start", "tape_low2_slot_start", "tape_low3_slot_start"):
        a = sym.get(name)
        hit = [(ad, d) for ad, d in segs if ad == a] if a is not None else []
        if hit:
            ok = same_outside_rewritten(a, hit[0][1])
            print(f"  {name} ${a:04x} ({len(hit[0][1])} bytes): {'byte-identical (boot-rewritten windows excepted)' if ok else 'DIFFERS'}")

    if fails:
        print("FAIL:")
        for f in fails:
            print("  - " + f)
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
