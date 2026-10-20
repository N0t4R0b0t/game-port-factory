#!/usr/bin/env python3
"""harness/floppy_dir_check.py -- T0241: Disk BASIC's OWN view of target/dizzy.dsk must match tools/dskwriter's.

Boots XRoar with Disk Extended BASIC 1.1 and the image, types DIR (and FILES via DSKI$-free means:
only DIR), reads the 32x16 text screen over the GDB stub and compares every directory line
(NAME EXT TYPE ASCII-FLAG GRANULES) with `dskwriter ls`.  Disk BASIC prints, per file:
    DIZZY   OVL  1 B  4        (type 0 BASIC / 1 data / 2 machine code / 3 text, B = binary or A = ascii, granules)
and ends with the free-granule count.  Exit 0 = PASS.

Usage: python3 harness/floppy_dir_check.py [--dsk PATH]
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
from gdb_run import Target  # noqa: E402
from screen_text import decode  # noqa: E402

DSK = Path(sys.argv[sys.argv.index("--dsk") + 1]) if "--dsk" in sys.argv else ROOT / "target/dizzy.dsk"
LS = ROOT / "tools/dskwriter/target/release/dskwriter"


def main():
    want = {}
    for line in subprocess.check_output([str(LS), "ls", str(DSK)], text=True).splitlines():
        m = re.match(r"(\S+)\s+type=(\d) ascii=([0-9a-f]{2}) gran=(\d+) track=\d+ sector=\d+ granules=(\d+)", line)
        name, typ, asc, _, grans = m.groups()
        n, e = name.split(".")
        want[(n, e)] = (int(typ), "A" if asc != "00" else "B", int(grans))
    port = 20000 + random.randrange(40000)
    proc = subprocess.Popen(
        ["xroar", "-ui", "null", "-machine", "coco2bus", "-rompath", str(ROOT / "source/roms"),
         "-bas", "BASIC.ROM", "-extbas", "EXTBASIC.ROM", "-cart", "rsdos", "-cart-type", "rsdos",
         "-cart-rom", "DSKBASIC.ROM", "-load-fd0", str(DSK), "-no-disk-write-back", "-no-ratelimit",
         "-type", "DIR\r", "-gdb", "-gdb-port", str(port)],
        stdout=open("/tmp/floppy_dir_check.log", "w"), stderr=subprocess.STDOUT)
    try:
        time.sleep(5)
        t = None
        for _ in range(80):
            try:
                t = Target("127.0.0.1", port)
                break
            except OSError:
                time.sleep(0.1)
        t.running = False
        t.run_for(1.0)
        scr = decode(t.read(0x400, 512))
        t.close()
    finally:
        proc.terminate()
    print(scr)
    got = {}
    for line in scr.splitlines():
        m = re.match(r"^(\S{1,8})\s+(\S{1,3})\s+(\d)\s+([AB])\s+(\d+)", line.strip())
        if m:
            got[(m.group(1), m.group(2))] = (int(m.group(3)), m.group(4), int(m.group(5)))
    if got == want and want:
        print(f"PASS: Disk BASIC DIR lists the same {len(want)} files as dskwriter (name, ext, type, B/A, granules)")
        return 0
    print(f"FAIL: DIR shows {got}\n      dskwriter shows {want}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
