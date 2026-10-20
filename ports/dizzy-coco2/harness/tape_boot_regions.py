#!/usr/bin/env python3
"""harness/tape_boot_regions.py -- T0219: after a REAL tape boot, diff what
actually sits in RAM against target/room36_tape.bin, segment by segment.

Why this exists: the memory-poke harnesses (MAME load_decb, jumptrace, ...)
write every DECB block in file order into RAM and so can NEVER see a
load-ORDER overwrite -- the T0219 bug was tape_stage1 (a running loader)
being overwritten by a later tape segment, and every poke harness was green
while the real tape boot was dead. Only a real boot (XRoar -load-tape,
CLOADM + EXEC, real ROM cassette I/O, stage1's own segment copier) can
catch that class, so this diffs the result.

What is checked (all after the real boot has settled in the title wait):

  1. boot sanity: PIA0 CRA DDR-select bit set; title is PLAYING (PC samples
     inside the mixer blob TITLE_RAW_BUF..+TITLE_RAW_LEN, bootreal.py's
     check) -- a boot that died or skipped the title fails here.
  2. the tape-only region [IMAGE_END, tape_room_staged_end): byte-identical.
  3. EVERY other tape segment's final bytes: each byte of room36_tape.bin
     must be in RAM unchanged unless it lies in a window that boot
     legitimately consumes/rewrites (REWRITTEN below, with the reason for
     each; the title framebuffers, the relocated start: code, mutable
     state). Anything else that differs is a load-order overwrite or a
     boot bug and FAILS, with the first offending address.
  3b. (T0220) the TAPE_LOW_REGION content (Dozy text, slot start..end) is an
     ordinary segment of room36_tape.bin: loaded bytes are diffed (checked 3).
  3c. (T0221) TAPE_LOW_REGION2 (gap1 $5CE2-$5FFF, the completion tune's LZ blob)
      is likewise a segment: byte-diffed after boot, reported explicitly.
  3d. (T0223/T0224) TAPE_LOW_REGION3 ([code_data_end, $4000): since T0224 the whole old
      title hole 1): content byte-diffed after boot when non-empty; its free tail is
      covered by the pattern test (4).
  3e. (T0224) TAPE_LOW_REGION4 ([low_region_end, $0E00), the old title hole 0): empty
      today, whole region covered by the pattern test (4).
  3f. (T0224) blocks C and D now travel as RAW segments (tape_c_raw_start @RC_DEST,
      tape_d_raw_start @CODE_DEST), copied up by stage1 and no longer unpacked at boot:
      each must be byte-identical to room36_tape.bin after the real boot (explicit lines).
  4. TAPE_LOW_REGION (and, T0221, TAPE_LOW_REGION2, T0223 TAPE_LOW_REGION3) free tail [tape_low_slot_end, TAPE_LOW_END): second boot of a cas
     built with a PATTERN segment covering the whole region (same tapepack
     + stage1 as tools/tape_pack.sh produced, one extra segment): the
     pattern must come out byte-identical, proving nothing at boot (gather,
     title unpack, nibswap build, ...) writes there. T0225b: the LOW region now runs up to nibswap ($7F00). Skipped with
     --no-pattern.

Usage:  python3 harness/tape_boot_regions.py [--no-pattern] [--cas PATH --stage1-bin PATH --stage1-map PATH]
(the --cas/--stage1-* overrides exist to run the harness against a
deliberately broken image -- negative test of this harness itself.)
Run tools/tape_pack.sh first (twice if title sizes moved). Exit 0 = PASS.
"""
import os
import random
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))
from gdb_run import Target, pkt, recv_reply  # noqa: E402

CAS = ROOT / "target/room36.cas"
TAPE_BIN = ROOT / "target/room36_tape.bin"
TAPE_MAP = ROOT / "target/room36_tape.map"
STAGE1_BIN = Path("/tmp/tape_stage1.bin")
STAGE1_MAP = Path("/tmp/tape_stage1.map")
TAPEPACK = ROOT / "tools/caswriter/target/release/tapepack"


def _arg(name, default):
    return Path(sys.argv[sys.argv.index(name) + 1]) if name in sys.argv else default


CAS = _arg("--cas", CAS)
STAGE1_BIN = _arg("--stage1-bin", STAGE1_BIN)
STAGE1_MAP = _arg("--stage1-map", STAGE1_MAP)


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


def boot(cas, mix_lo, mix_hi, want_mem, tag):
    """T0225: retry wrapper. xroar's gdb stub wedges if we connect before
    the tape read has finished (T0227); the fixed settle time stopped
    being enough as the .cas grew (~1 in 2 first runs timed out). Each
    retry is a FRESH xroar with a longer settle."""
    last = None
    for settle in (6.0, 10.0, 14.0):
        try:
            return _boot_once(cas, mix_lo, mix_hi, want_mem, tag, settle)
        except (TimeoutError, OSError) as e:
            last = e
            print(f"  (boot {tag}: gdb {type(e).__name__} after {settle:.0f}s settle -- retrying with a fresh xroar)")
    raise last


def _boot_once(cas, mix_lo, mix_hi, want_mem, tag, settle):
    """Real tape boot of `cas`; returns (live_memory dict addr->bytes, notes).
    want_mem = list of (addr, length) to read back."""
    port = 20000 + random.randrange(40000)
    log = open(f"/tmp/dizzy-coco2-tape-regions-{tag}.log", "w")
    proc = subprocess.Popen(
        ["xroar", "-ui", "null", "-machine", "coco2bus",
         "-rompath", str(ROOT / "source/roms"),
         "-bas", "BASIC.ROM", "-extbas", "EXTBASIC.ROM",
         "-no-ratelimit",
         "-load-tape", str(cas), "-type", "CLOADM\rEXEC\r",
         "-gdb", "-gdb-port", str(port)],
        stdout=log, stderr=subprocess.STDOUT)
    try:
        # T0227: connect to GDB only after the tape read has finished.
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
                fails.append("PIA0 CRA DDR-select bit clear: " +
                             " ".join(f"${c:02x}" for _, c in samples))
            in_mixer = sum(1 for pc, _ in samples if mix_lo <= pc < mix_hi)
            if in_mixer < len(samples) - 1:
                fails.append(f"title is NOT playing: only {in_mixer}/{len(samples)} PC "
                             f"samples inside the mixer ${mix_lo:04x}-${mix_hi:04x} "
                             f"(PCs: {' '.join(f'${pc:04x}' for pc, _ in samples)})")
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
    no_pattern = "--no-pattern" in sys.argv
    for f in (CAS, TAPE_BIN, TAPE_MAP, STAGE1_BIN, STAGE1_MAP):
        if not f.exists():
            print(f"FAIL: {f} missing -- run tools/tape_pack.sh first")
            return 1
    sym = symbols(TAPE_MAP)
    s1 = symbols(STAGE1_MAP)
    mix_lo = sym["TITLE_RAW_BUF"]
    mix_hi = mix_lo + sym["TITLE_RAW_LEN"]
    segs = decb_segments(TAPE_BIN)
    low_s, low_e = sym["TAPE_LOW_START"], sym["TAPE_LOW_END"]
    low2_s, low2_e = sym["TAPE_LOW2_START"], sym["TAPE_LOW2_END"]
    low3_s, low3_e = sym["TAPE_LOW3_START"], sym["TAPE_LOW3_END"]
    low4_s, low4_e = sym["TAPE_LOW4_START"], sym["TAPE_LOW4_END"]
    s1_org, s1_end = s1["STAGE1_ORG"], s1["STAGE1_END"]
    fails = []

    # Windows that boot LEGITIMATELY rewrites after the tape load, so a
    # difference from room36_tape.bin there is expected (name, lo, hi,
    # reason). Everything outside these must be byte-identical.
    rewritten = [
        ("framebuffer A $4000-$57FF", 0x4000, 0x5800,
         "staged block A relocated to $8000+, then gather buffer, then the title image"),
        ("framebuffer B $6000-$77FF", 0x6000, 0x7800,
         "staged block B relocated, then title-unpack scratch, then title copy"),
        # T0225b (L3): start: now lives in the FB A spare tail (inside the first window above), not at $0E00.
        ("boot variables ti_len..lz_state", sym["ti_len"], sym["lz_state"] + 1,
         "ti_len/ti_coln/ti_rown and lz_unpack's lz_* state: written by the gather/unpack"),
    ]
    # Segments that hold mutable game state: reads here are only meaningful
    # as "same as image" while the game has not run, which holds at the
    # title wait; no exemption is needed beyond the above.
    want = [(s, len(d)) for s, d in segs]
    want.append((s1_org, s1_end - s1_org))
    nib = sym["nibswap"]
    want.append((nib, 256))      # T0225b: nibswap is built by start: BEFORE the title now

    print(f"real tape boot of {CAS.name}: {len(segs)} DECB segments, stage1 "
          f"${s1_org:04x}-${s1_end:04x}, TAPE_LOW_REGION ${low_s:04x}-${low_e:04x}")
    res = boot(CAS, mix_lo, mix_hi, want, "main")
    if res[0] is None:
        print("FAIL: " + res[1][0])
        return 1
    mem, bfails, in_mixer, nsamp = res
    fails += bfails
    print(f"boot: title playing: {in_mixer}/{nsamp} PC samples in mixer "
          f"${mix_lo:04x}-${mix_hi:04x}")

    # T0225b (L3): start: runs from the FB A spare tail; the tape EXEC address (DECB trailer) must be it,
    # it must be a tape segment, and nothing may still sit at $0E00 as `start`.
    raw = TAPE_BIN.read_bytes()
    exec_addr = raw[-2] * 256 + raw[-1] if raw[-5:-2] == b"\xff\x00\x00" else None
    st_s, st_e = sym["start"], sym["tape_start_end"]
    sseg = [(a, d) for a, d in segs if a == st_s]
    if exec_addr != st_s:
        fails.append(f"DECB EXEC address {exec_addr and hex(exec_addr)} is not start ${st_s:04x}")
    if not sseg or len(sseg[0][1]) != st_e - st_s:
        fails.append(f"start: ${st_s:04x}-${st_e:04x} is not its own tape segment")
    elif not (0x4000 <= st_s and st_e <= 0x5800):
        fails.append(f"start: ${st_s:04x}-${st_e:04x} is not inside the FB A spare (<$5800)")
    else:
        print(f"start: ${st_s:04x}-${st_e:04x} ({st_e - st_s} bytes) in the FB A spare tail is the DECB EXEC "
              f"address and ran (title playing)")
    if sym["new_game"] != 0x0E00:
        fails.append(f"new_game is ${sym['new_game']:04x}, expected $0E00 (L3 layout)")
    # nibswap: built by start: before show_title; every entry must be the nibble rotation, in RAM after boot.
    want_nib = bytes((((s & 15) << 4) | (s >> 4)) for s in range(256))
    got_nib = bytes(mem[nib][(i + 128) & 255] for i in range(256))
    # entry for s lives at (s+128)&255
    if got_nib != want_nib:
        nbad = sum(1 for i in range(256) if got_nib[i] != want_nib[i])
        fails.append(f"nibswap table wrong after boot: {nbad} of 256 entries differ")
    else:
        print(f"nibswap ${nib:04x}-${nib+256:04x}: all 256 entries correct after the real boot "
              f"(built by start: before the title)")

    exempt_total = checked = 0
    tape_lo, tape_hi = sym["tape_room_staged_start"], sym["tape_room_staged_end"]
    for ad, data in segs:
        live = mem[ad]
        bad_first = None
        bad_n = ex_n = 0
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
            fails.append(f"segment ${ad:04x}-${ad+len(data):04x}: {bad_n} byte(s) differ after "
                         f"boot, first at ${a:04x} got ${got:02x} expected ${exp:02x}"
                         + ("  [THIS IS THE TAPE-ONLY REGION]" if tape_lo <= ad < tape_hi else ""))
    print(f"segments: {checked} bytes of {len(segs)} tape segments compared; "
          f"{exempt_total} differ only inside boot-rewritten windows "
          f"({', '.join(n for n, *_ in rewritten)}); the rest are byte-identical"
          if not [f for f in fails if f.startswith('segment')]
          else "segments: MISMATCH (see below)")

    # tape-only region explicit line (the original tape_room_warp check)
    te = [(a, d) for a, d in segs if a == tape_lo]
    if te:
        ok = mem[tape_lo] == te[0][1]
        print(f"tape-only region ${tape_lo:04x}-${tape_lo+len(te[0][1]):04x} "
              f"({len(te[0][1])} bytes): {'byte-identical' if ok else 'DIFFERS'}")

    # T0220: the persistent low region now carries real content
    # (tape_low_slot_start..end: Dozy's dozytalking + kick text). It is one
    # of the DECB segments above, so the loop already byte-compared it; say
    # so explicitly here, and fail if the slot's segment is missing.
    slot_s, slot_e = sym["tape_low_slot_start"], sym["tape_low_slot_end"]
    lseg = [(a, d) for a, d in segs if a == slot_s]
    if slot_e > slot_s:
        if not lseg or len(lseg[0][1]) != slot_e - slot_s:
            fails.append(f"TAPE_LOW_REGION content ${slot_s:04x}-${slot_e:04x} is not a tape segment")
        else:
            ok = mem[slot_s] == lseg[0][1]
            print(f"TAPE_LOW_REGION content ${slot_s:04x}-${slot_e:04x} ({slot_e - slot_s} bytes, "
                  f"{low_e - slot_e} free after it): loaded over the real tape and "
                  f"{'byte-identical to room36_tape.bin' if ok else 'DIFFERS'}")
            if not ok:
                fails.append(f"TAPE_LOW_REGION content differs from room36_tape.bin after boot")
    else:
        print(f"TAPE_LOW_REGION is empty ({low_e - low_s} bytes reserved)")

    # T0221: TAPE_LOW_REGION2 content (the completion tune's packed mixer blob).
    s2_s, s2_e = sym["tape_low2_slot_start"], sym["tape_low2_slot_end"]
    lseg2 = [(a, d) for a, d in segs if a == s2_s]
    if not lseg2 or len(lseg2[0][1]) != s2_e - s2_s or s2_e <= s2_s:
        fails.append(f"TAPE_LOW_REGION2 content ${s2_s:04x}-${s2_e:04x} is not a tape segment")
    else:
        ok = mem[s2_s] == lseg2[0][1]
        print(f"TAPE_LOW_REGION2 content ${s2_s:04x}-${s2_e:04x} ({s2_e - s2_s} bytes, "
              f"{low2_e - s2_e} free after it): loaded over the real tape and "
              f"{'byte-identical to room36_tape.bin' if ok else 'DIFFERS'}")
        if not ok:
            fails.append("TAPE_LOW_REGION2 content differs from room36_tape.bin after boot")

    # T0223: TAPE_LOW_REGION3 content (tail of title hole 1). Its content is
    # one DECB segment starting at tape_low3_slot_start (absent when empty).
    s3_s, s3_e = sym["tape_low3_slot_start"], sym["tape_low3_slot_end"]
    if s3_s != low3_s:
        fails.append(f"tape_low3_slot_start ${s3_s:04x} != TAPE_LOW3_START ${low3_s:04x}")
    if s3_e > low3_e:
        fails.append(f"TAPE_LOW_REGION3 content ends ${s3_e:04x}, past TAPE_LOW3_END ${low3_e:04x}")
    if s3_e > s3_s:
        lseg3 = [(a, d) for a, d in segs if a == s3_s]
        if not lseg3 or len(lseg3[0][1]) != s3_e - s3_s:
            fails.append(f"TAPE_LOW_REGION3 content ${s3_s:04x}-${s3_e:04x} is not a tape segment")
        else:
            ok = mem[s3_s] == lseg3[0][1]
            print(f"TAPE_LOW_REGION3 content ${s3_s:04x}-${s3_e:04x} ({s3_e - s3_s} bytes, "
                  f"{low3_e - s3_e} free after it): loaded over the real tape and "
                  f"{'byte-identical to room36_tape.bin' if ok else 'DIFFERS'}")
            if not ok:
                fails.append("TAPE_LOW_REGION3 content differs from room36_tape.bin after boot")
    else:
        print(f"TAPE_LOW_REGION3 is empty (${low3_s:04x}-${low3_e:04x}, {low3_e - low3_s} bytes reserved)")
    # T0224: TAPE_LOW_REGION4 (old hole 0): empty slot; free whole region (pattern test below).
    s4_s, s4_e = sym["tape_low4_slot_start"], sym["tape_low4_slot_end"]
    if s4_s != low4_s:
        fails.append(f"tape_low4_slot_start ${s4_s:04x} != TAPE_LOW4_START ${low4_s:04x}")
    if s4_e > low4_e:
        fails.append(f"TAPE_LOW_REGION4 content ends ${s4_e:04x}, past TAPE_LOW4_END ${low4_e:04x}")
    if s4_e > s4_s:
        l4 = [(a, d) for a, d in segs if a == s4_s]
        if not l4 or len(l4[0][1]) != s4_e - s4_s or mem[s4_s] != l4[0][1]:
            fails.append("TAPE_LOW_REGION4 content missing or differs after boot")
        else:
            print(f"TAPE_LOW_REGION4 content ${s4_s:04x}-${s4_e:04x}: byte-identical")
    else:
        print(f"TAPE_LOW_REGION4 is empty (${low4_s:04x}-${low4_e:04x}, {low4_e - low4_s} bytes reserved)")
    # T0224: raw blocks C and D must be segments and byte-identical after boot
    # (nothing unpacks into RC_DEST/CODE_DEST any more).
    for nm, lbl, endsym in (("C", "tape_c_raw_start", "tape_c_raw_end"), ("D", "tape_d_raw_start", "tape_d_raw_end")):
        a0, a1 = sym[lbl], sym[endsym]
        seg = [(a, d) for a, d in segs if a == a0]
        if not seg or len(seg[0][1]) != a1 - a0:
            fails.append(f"raw block {nm} ${a0:04x}-${a1:04x} is not a tape segment")
        else:
            ok = mem[a0] == seg[0][1]
            print(f"raw block {nm} ${a0:04x}-${a1:04x} ({a1 - a0} bytes, delivered by stage1's >=$8000 copy): "
                  f"{'byte-identical to room36_tape.bin' if ok else 'DIFFERS'}")
            if not ok:
                fails.append(f"raw block {nm} differs from room36_tape.bin after boot")
    if "title_lz0" in sym or "title_lz1" in sym:
        fails.append("title_lz* fragments still exist in the tape build (T0224 removed the holes)")

    if not no_pattern:
        # Pattern boot: same stage1 + tapepack, plus one extra segment that
        # fills the WHOLE low region with a position-dependent pattern.
        # (T0220: only the FREE tail [tape_low_slot_end, TAPE_LOW_END); the
        # slot itself holds real content, checked above.)
        pat_s = slot_e
        pat = bytes((0xA5 ^ (i * 7) ^ (i >> 8)) & 0xFF for i in range(low_e - pat_s))
        tmpd = tempfile.mkdtemp(prefix="tape_low_pat_")
        patf = os.path.join(tmpd, "pat.bin")
        open(patf, "wb").write(pat)
        # T0221: region 2's free tail [tape_low2_slot_end, TAPE_LOW2_END)
        pat2_s = s2_e
        pat2 = bytes((0x5A ^ (i * 11) ^ (i >> 8)) & 0xFF for i in range(low2_e - pat2_s))
        pat2f = os.path.join(tmpd, "pat2.bin")
        open(pat2f, "wb").write(pat2)
        # T0223: region 3's free tail [tape_low3_slot_end, TAPE_LOW3_END)
        pat3_s = s3_e
        pat3 = bytes((0x3C ^ (i * 13) ^ (i >> 8)) & 0xFF for i in range(low3_e - pat3_s))
        pat3f = os.path.join(tmpd, "pat3.bin")
        open(pat3f, "wb").write(pat3)
        # T0224: region 4 (whole, empty slot): [tape_low4_slot_end, TAPE_LOW4_END)
        pat4_s = s4_e
        pat4 = bytes((0x69 ^ (i * 17) ^ (i >> 8)) & 0xFF for i in range(low4_e - pat4_s))
        pat4f = os.path.join(tmpd, "pat4.bin")
        open(pat4f, "wb").write(pat4)
        pcas = os.path.join(tmpd, "room36_pat.cas")
        # What the real build would do with such content: re-run the same
        # stage1 placement rules is tools/tape_pack.sh's job; here stage1 is
        # the one that build produced (outside the low region by construction).
        cmd = [str(TAPEPACK), "--stage1-bin", str(STAGE1_BIN),
               "--stage1-addr", f"{s1_org:x}", "--decb", str(TAPE_BIN),
               "--extra-segment", f"{pat_s:x}:{patf}",
               "--extra-segment", f"{pat2_s:x}:{pat2f}",
               "--extra-segment", f"{pat3_s:x}:{pat3f}",
               "--extra-segment", f"{pat4_s:x}:{pat4f}", "--out", pcas]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            fails.append("could not build the pattern cas: " + (r.stderr or r.stdout).strip())
        else:
            res2 = boot(Path(pcas), mix_lo, mix_hi,
                        [(pat_s, low_e - pat_s), (pat2_s, low2_e - pat2_s),
                         (pat3_s, low3_e - pat3_s), (pat4_s, low4_e - pat4_s)], "pattern")
            if res2[0] is None:
                fails.append("pattern boot: " + res2[1][0])
            else:
                mem2, bf2, _, _ = res2
                fails += ["pattern boot: " + x for x in bf2]
                if mem2[pat2_s] != pat2:
                    nbad2 = sum(1 for i in range(len(pat2)) if mem2[pat2_s][i] != pat2[i])
                    fails.append(f"TAPE_LOW_REGION2 pattern clobbered: {nbad2} of {len(pat2)} bytes differ")
                else:
                    print(f"TAPE_LOW_REGION2 free tail ${pat2_s:04x}-${low2_e:04x}: {len(pat2)}-byte pattern "
                          f"loaded over the real tape survives boot byte-identical (title playing)")
                if mem2[pat4_s] != pat4:
                    nbad4 = sum(1 for i in range(len(pat4)) if mem2[pat4_s][i] != pat4[i])
                    fails.append(f"TAPE_LOW_REGION4 pattern clobbered: {nbad4} of {len(pat4)} bytes differ")
                else:
                    print(f"TAPE_LOW_REGION4 ${pat4_s:04x}-${low4_e:04x}: {len(pat4)}-byte pattern "
                          f"loaded over the real tape survives boot byte-identical (title playing)")
                if mem2[pat3_s] != pat3:
                    nbad3 = sum(1 for i in range(len(pat3)) if mem2[pat3_s][i] != pat3[i])
                    fails.append(f"TAPE_LOW_REGION3 pattern clobbered: {nbad3} of {len(pat3)} bytes differ")
                else:
                    print(f"TAPE_LOW_REGION3 free tail ${pat3_s:04x}-${low3_e:04x}: {len(pat3)}-byte pattern "
                          f"loaded over the real tape survives boot byte-identical (title playing)")
                live2 = mem2[pat_s]
                if live2 != pat:
                    first = next(i for i in range(len(pat)) if live2[i] != pat[i])
                    nbad = sum(1 for i in range(len(pat)) if live2[i] != pat[i])
                    fails.append(f"TAPE_LOW_REGION pattern clobbered: {nbad} of {len(pat)} bytes "
                                 f"differ, first at ${pat_s+first:04x} got ${live2[first]:02x} "
                                 f"expected ${pat[first]:02x}")
                else:
                    print(f"TAPE_LOW_REGION free tail ${pat_s:04x}-${low_e:04x}: {len(pat)}-byte pattern "
                          f"loaded over the real tape survives boot byte-identical (title playing)")

    if fails:
        print("TAPE_BOOT_REGIONS FAIL")
        for f in fails:
            print("  " + f)
        return 1
    print("TAPE_BOOT_REGIONS PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
