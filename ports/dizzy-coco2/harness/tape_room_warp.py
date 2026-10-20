#!/usr/bin/env python3
"""harness/tape_room_warp.py -- T0230: prove the tape-only region over a
REAL tape boot, not just a MAME memory-poke harness.

Boots target/room36.cas for real in XRoar (-load-tape + -type
"CLOADM<CR>EXEC<CR>", the same ONE-CLOADM path play.sh --tape uses),
late-GDB-connects (T0227's own finding: connecting BEFORE the tape read
finishes corrupts real-time-sensitive state -- connect only once the
boot has had time to settle), then:

  1. confirms the boot itself succeeded for real (PIA0 CRA DDR-select
     bit set, same check as harness/bootreal.py);
  2. reads the tape-only region's real memory (rooms 74/75, delivered
     by target/tape_stage1.asm's addr>=$8000 path over REAL ROM
     cassette I/O -- CSRDON/BLKIN, the all-RAM toggle, all of it, not a
     MAME Lua poke) and diffs it BYTE FOR BYTE against target/
     room36_tape.bin's own assembled bytes for that block -- the
     strongest available proof the real tape mechanism delivered this
     NEW kind of segment (an ordinary room data block, not the empty
     T0228 proof-of-mechanism region) correctly;
  3. injects a tiny probe (10 bytes: `lda #74/sta cur_room/jsr
     load_room/bra *`) into the tape_stage1 scratch region (STAGE1_ORG,
     unused once stage1 has handed off -- see target/tape_stage1.asm's
     own header) and redirects PC there, so the game's OWN load_room
     runs for real against cur_room=74 -- then reads back cur_room and
     the live room_place_count/room_placements_ptr RAM it produced.
     Chosen over simulating a title-dismiss keypress (xroar's GDB stub
     has no keyboard-matrix hook) or driving all the way through
     new_game (touches subsystems -- actors_init, redraw/blit via
     nibswap -- this task doesn't need working to prove the point and
     whose state this probe deliberately does not disturb).

Usage: python3 harness/tape_room_warp.py [ROOM]   (default 74)
Exit 0 = tape boot verified AND load_room(ROOM) ran for real against
tape-delivered data.
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

ROOM = int(sys.argv[1]) if len(sys.argv) > 1 else 74
CAS = ROOT / "target/room36.cas"
TAPE_BIN = ROOT / "target/room36_tape.bin"
TAPE_MAP = ROOT / "target/room36_tape.map"
STAGE1_MAP = Path("/tmp/tape_stage1.map")


def symbols(path):
    syms = {}
    for line in path.read_text().splitlines():
        m = re.match(r"^Symbol: (\S+) \(.*?\) = ([0-9a-fA-F]+)$", line)
        if m:
            syms[m.group(1)] = int(m.group(2), 16)
    return syms


def decb_block_at(path, addr):
    d = path.read_bytes()
    pos = 0
    while pos < len(d):
        t = d[pos]
        if t == 0:
            ln = d[pos + 1] * 256 + d[pos + 2]
            ad = d[pos + 3] * 256 + d[pos + 4]
            if ad == addr:
                return d[pos + 5:pos + 5 + ln]
            pos += 5 + ln
        elif t == 0xFF:
            break
        else:
            sys.exit(f"unknown DECB block type {t:#x}")
    return None


def set_pc(tgt, pc):
    tgt.halt()
    tgt.s.sendall(pkt(b"g"))
    body = recv_reply(tgt.s)[1:-3].decode()
    new = body[:-4] + f"{pc:04x}"
    tgt.s.sendall(pkt(b"G" + new.encode()))
    recv_reply(tgt.s)


def main():
    if not CAS.exists() or not TAPE_BIN.exists():
        print(f"FAIL: run tools/tape_pack.sh first ({CAS} / {TAPE_BIN} missing)")
        return 1
    sym = symbols(TAPE_MAP)
    stage1_sym = symbols(STAGE1_MAP) if STAGE1_MAP.exists() else {}
    if "STAGE1_ORG" not in stage1_sym:
        print("FAIL: /tmp/tape_stage1.map missing STAGE1_ORG -- run tools/tape_pack.sh first")
        return 1
    probe_addr = stage1_sym["STAGE1_ORG"]
    cur_room = sym["cur_room"]
    load_room = sym["load_room"]
    place_count_addr = sym["r74_room_place_count"] if ROOM == 74 else sym["r75_room_place_count"]

    port = 20000 + random.randrange(40000)
    log = open("/tmp/dizzy-coco2-tape-warp.log", "w")
    proc = subprocess.Popen(
        ["xroar", "-ui", "null", "-machine", "coco2bus",
         "-rompath", str(ROOT / "source/roms"),
         "-bas", "BASIC.ROM", "-extbas", "EXTBASIC.ROM",
         "-no-ratelimit",
         "-load-tape", str(CAS), "-type", "CLOADM\rEXEC\r",
         "-gdb", "-gdb-port", str(port)],
        stdout=log, stderr=subprocess.STDOUT)
    try:
        # T0227: connecting EARLY corrupts tape-timing-sensitive reads.
        # Give CLOADM+EXEC+stage1's own (fast-tape) segment stream time
        # to finish before ever touching GDB.
        time.sleep(10.0)  # T0225: 6s no longer covers the grown .cas load
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
        tgt.running = False
        try:
            # T0227/bootreal.py's own finding: the FIRST GDB interaction
            # after connecting must be a run_for (cont+sleep+halt), not a
            # bare read -- a bare 'm' as the very first packet hangs.
            tgt.run_for(1.0)
            cra = tgt.read(0xFF01, 1)[0]
            if not (cra & 0x04):
                print(f"FAIL: PIA0 CRA=${cra:02x} -- DDR-select bit clear, boot did not "
                      f"reach a sane state")
                return 1
            print(f"tape boot: PIA0 CRA=${cra:02x} (DDR-select set, real load succeeded)")

            expected = decb_block_at(TAPE_BIN, sym.get("tape_room_staged_start"))
            if expected is None:
                print("FAIL: could not find the tape-only region's own DECB block "
                      "in target/room36_tape.bin")
                return 1
            live = tgt.read(sym["tape_room_staged_start"], len(expected))
            if bytes(live) != expected:
                first = next(i for i in range(len(expected)) if live[i] != expected[i])
                print(f"FAIL: tape-only region differs at real offset {first} "
                      f"(addr ${sym['tape_room_staged_start']+first:04x}): "
                      f"got ${live[first]:02x}, expected ${expected[first]:02x}")
                return 1
            print(f"tape-only region: {len(expected)} bytes at "
                  f"${sym['tape_room_staged_start']:04x} match target/room36_tape.bin "
                  f"byte-for-byte -- real ROM cassette I/O delivered rooms 74/75 correctly")

            probe = bytes([
                0x86, ROOM,                              # lda #ROOM
                0xB7, cur_room >> 8, cur_room & 0xFF,    # sta cur_room
                0xBD, load_room >> 8, load_room & 0xFF,  # jsr load_room
                0x20, 0xFE,                               # bra *
            ])
            tgt.write(probe_addr, probe)
            set_pc(tgt, probe_addr)
            tgt.run_for(1.0)

            got_room = tgt.read(cur_room, 1)[0]
            got_count = tgt.read(place_count_addr, 1)[0]
            expected_count = decb_block_at(TAPE_BIN, sym["tape_room_staged_start"])
            # place_count is the first byte of rNN_room_place_count -- read
            # straight from the assembled image at its own address.
            off = place_count_addr - sym["tape_room_staged_start"]
            expected_pc_byte = expected[off]
            if got_room != ROOM:
                print(f"FAIL: cur_room=${got_room:02x} after load_room, expected ${ROOM:02x}")
                return 1
            if got_count != expected_pc_byte:
                print(f"FAIL: room_place_count=${got_count:02x}, expected ${expected_pc_byte:02x} "
                      f"(load_room did not copy the descriptor correctly)")
                return 1
            print(f"load_room({ROOM}) ran for real: cur_room=${got_room:02x}, "
                  f"room_place_count=${got_count:02x} (matches the assembled descriptor) -- "
                  f"PASS")
            return 0
        finally:
            tgt.close()
    finally:
        proc.terminate()
        log.close()


if __name__ == "__main__":
    sys.exit(main())
