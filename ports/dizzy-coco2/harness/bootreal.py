#!/usr/bin/env python3
"""harness/bootreal.py -- T0172: boot the game THE WAY THE USER DOES.

Every other harness here pokes the DECB segments straight into MAME's RAM
and sets PC. That skips two things the real machine does:

  * it writes the bytes a `rmb` hole leaves out (the loader does NOT --
    those addresses keep whatever the machine had there), and
  * it inherits MAME's coco2b RAM-clear pattern rather than xroar's.

A 12-byte `rmb` pad in the boot path (room36.asm, RELOC_BOOT_BYTES) was
executed as uninitialised RAM for months because of exactly that: green
under MAME, and under xroar the garbage cleared PIA0 CRA's DDR-select bit,
so `lda $ff00` read DDRA (=0) and every key scanned as held down -- the
title mixer returned instantly (no music) and ti_release spun forever.

So this one boots xroar with -run, the real DECB load path, and asserts:
  * PIA0 CRA ($FF01) still has bit 2 (DDR select) set, so $FF00 is the
    keyboard and not the data-direction register;
  * with no key pressed, the title has NOT been dismissed -- the sampled
    PC is inside the mixer blob (TITLE_RAW_BUF..+TITLE_RAW_LEN), which is
    also the proof the title tune is actually playing.

Usage:  python3 harness/bootreal.py [target/room36.bin]
Exit 0 = the real load path boots into a playing title screen.
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

BIN = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "target/room36.bin"
MAP = BIN.with_suffix(".map")


def symbols():
    syms = {}
    for line in MAP.read_text().splitlines():
        m = re.match(r"^Symbol: (\S+) \(.*?\) = ([0-9a-fA-F]+)$", line)
        if m:
            syms[m.group(1)] = int(m.group(2), 16)
    return syms


def main():
    sym = symbols()
    mix_lo = sym["TITLE_RAW_BUF"]
    mix_hi = mix_lo + sym["TITLE_RAW_LEN"]
    port = 20000 + random.randrange(40000)
    log = open("/tmp/dizzy-coco2-bootreal.log", "w")
    # -no-ratelimit is REQUIRED, not an optimisation: with the rate limiter
    # on (and no audio device in a headless run) this stub answers `g` but
    # never answers the 0x03 interrupt, so every halt times out. Unthrottled
    # it runs ~50x, which is why the sleeps below are fractions of a second.
    proc = subprocess.Popen(
        ["xroar", "-ui", "null", "-machine", "coco2bus",
         "-rompath", str(ROOT / "source/roms"),
         "-bas", "BASIC.ROM", "-extbas", "EXTBASIC.ROM",
         "-run", str(BIN), "-no-ratelimit", "-gdb", "-gdb-port", str(port)],
        stdout=log, stderr=subprocess.STDOUT)
    try:
        # Give xroar time to boot BASIC and run the real DECB load.
        time.sleep(3.0)
        tgt = None
        for _ in range(80):
            try:
                tgt = Target("127.0.0.1", port)
                break
            except OSError:
                time.sleep(0.1)
        if tgt is None:
            print("FAIL: xroar's gdb stub never came up")
            return 1
        # NB: this stub does not answer `?` -- drive it with c / 0x03 only
        # (see gdb_run.py's header). running=False so the first run_for
        # sends `c`, not an interrupt into an already-running target.
        tgt.running = False
        fails, samples = [], []
        try:
            for _ in range(8):       # unthrottled, so ~50s of title each
                tgt.run_for(1.0)
                tgt.s.sendall(pkt(b"g"))
                pc = int(recv_reply(tgt.s)[1:-3].decode()[-4:], 16)
                cra = tgt.read(0xFF01, 1)[0]
                samples.append((pc, cra))
        except (TimeoutError, OSError, ValueError) as exc:
            print("BOOTREAL FAIL: lost the target after %d sample(s) (%s) -- "
                  "samples so far: %s"
                  % (len(samples), exc,
                     " ".join("$%04x/CRA=$%02x" % s for s in samples)))
            return 1
        tgt.close()
        cras = {c for _, c in samples}
        if not all(c & 0x04 for c in cras):
            fails.append(
                "PIA0 CRA ($FF01) = %s -- bit 2 (DDR select) is CLEAR, so "
                "`lda $ff00` reads DDRA, not the keyboard: every key scans "
                "as held down" % ", ".join("$%02x" % c for c in sorted(cras)))
        in_mixer = sum(1 for pc, _ in samples if mix_lo <= pc < mix_hi)
        if in_mixer < len(samples) - 1:
            fails.append(
                "only %d/%d samples were inside the title mixer "
                "($%04x-$%04x); PCs seen: %s -- the title was dismissed with "
                "no key pressed, or never started"
                % (in_mixer, len(samples), mix_lo, mix_hi,
                   " ".join("$%04x" % pc for pc, _ in samples)))
        if fails:
            print("BOOTREAL FAIL")
            for f in fails:
                print("  " + f)
            return 1
        print("BOOTREAL PASS: real DECB load boots into the title, CRA=$%02x, "
              "%d/%d samples in the mixer" % (samples[0][1], in_mixer,
                                              len(samples)))
        return 0
    finally:
        proc.terminate()
        log.close()


if __name__ == "__main__":
    sys.exit(main())
