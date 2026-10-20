#!/usr/bin/env python3
"""Print Dizzy's live room/x/y from a RUNNING xroar, over its gdb stub.

WHY THIS EXISTS: four rounds of this session were spent guessing which
platform a playtest report meant ("the very edge of the top of the
table") and reproducing the wrong jump each time -- the railing shelf at
y=88, then the table's left edge, then a sweep of the whole table. Each
guess cost a full measurement cycle. Two numbers off the real screen ends
that.

Needs no change to the game: it reads dizzy_x/dizzy_y/cur_room out of
RAM by name from target/room36.map.

  1. start the game with the stub open:   PLAY_GDB=1 ./play.sh
  2. in another terminal:                 python3 tools/coords.py
  3. stand where you want, read the line, tell me the numbers.

Prints only when the values change, so holding still is quiet.
"""
import re
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "harness"))
from gdb_run import Target  # noqa: E402

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 21000
MAP = ROOT / "target/room36.map"


def main():
    sym = {}
    for line in MAP.read_text().splitlines():
        m = re.match(r"^Symbol: (\S+) \(.*?\) = ([0-9a-fA-F]+)$", line)
        if m:
            sym[m.group(1)] = int(m.group(2), 16)
    need = ("cur_room", "dizzy_x", "dizzy_y", "dizzy_floor", "lives")
    missing = [n for n in need if n not in sym]
    if missing:
        print(f"not in {MAP}: {missing}")
        return 1
    # play.sh rebuilds before launching, so the stub can take a while to
    # appear -- wait for it rather than failing on the first try.
    t = None
    for _ in range(120):
        try:
            t = Target("127.0.0.1", PORT)
            break
        except OSError:
            time.sleep(0.5)
    if t is None:
        print(f"no xroar gdb stub on port {PORT} after 60s. Start the game "
              f"with PLAY_GDB=1 ./play.sh  (or pass the port as argv[1])")
        return 1
    print("room   x    y   floor  lives      (Ctrl-C to stop)")
    last = None
    try:
        while True:
            # run_for already leaves the target halted, and read() halts
            # again only if it is running -- do NOT cont() here as well,
            # or the stub gets two continues for one interrupt and the
            # next halt times out.
            t.run_for(0.5)
            vals = tuple(t.read(sym[n], 1)[0] for n in need)
            if vals != last:
                print("%4d %4d %4d %5d %6d" % vals)
                last = vals
    except KeyboardInterrupt:
        print()
    finally:
        try:
            t.close()
        except Exception:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
