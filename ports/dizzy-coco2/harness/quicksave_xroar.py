#!/usr/bin/env python3
"""harness/quicksave_xroar.py -- T0242: quick save -> POWER OFF -> reboot the disk -> quick load, on XRoar (real Disk BASIC boot,
write-back image).  xroar has no way to press keys from a harness, so the two KEY-dependent spots are patched over gdb and
EVERYTHING ELSE is the real thing (conditions, overlay load, driver, state copy, header, boxes, rebuild):
  * `save_poll`'s first instruction becomes `bra sp_save` (phase 1) / `bra sv_do_load` (phase 2): "S / L is pressed";
  * `msg_wait_dismiss` becomes `rts`: "SPACE pressed" (the box is still drawn).
(The key scan itself is exercised by harness/quicksave.lua in MAME.)

  phase 1: boot, start the game (PC := new_game), poke marker state (coins 7, lives 1, inv[0], an actor byte), "press S",
           wait, read sv_code (0), let xroar exit CLEANLY at its emulated -timeout (that is what flushes the write-back disk).
  host:    the disk image now holds a valid DIZZY.SAV (header, build ID = this build, checksum) and `dskwriter check` passes.
  phase 2: a NEW xroar on that image (power-off/boot), start the game (coins 0, lives 2), "press L", wait, read the markers:
           must equal phase 1's; the game keeps running (passes advance).
  phase 3: boot the PRISTINE disk, "press L": sv_code == 1 (NO SAVED GAME) and the state is untouched.
Exit 0 = PASS.   Usage: python3 harness/quicksave_xroar.py
"""
import random, re, shutil, subprocess, sys, tempfile, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))
from gdb_run import Target, pkt, recv_reply  # noqa: E402

MAP = ROOT / "target/room36_floppy.map"
DSK = ROOT / "target/dizzy.dsk"
DSKW = ROOT / "tools/dskwriter/target/release/dskwriter"


def syms():
    d = {}
    for l in MAP.read_text().splitlines():
        m = re.match(r"^Symbol: (\S+) \(.*?\) = ([0-9A-Fa-f]+)$", l)
        if m:
            d[m.group(1)] = int(m.group(2), 16)
    return d


S = syms()
fails = 0


def check(name, ok, extra=""):
    global fails
    fails += 0 if ok else 1
    print(f"QSXR {'PASS' if ok else 'FAIL'} {name}" + (f" -- {extra}" if extra else ""), flush=True)


def regs(t):
    t.halt()
    t.s.sendall(pkt(b"g"))
    b = bytes.fromhex(recv_reply(t.s)[1:-3].decode())
    return dict(cc=b[0], a=b[1], b=b[2], dp=b[3], x=b[4] << 8 | b[5], y=b[6] << 8 | b[7], u=b[8] << 8 | b[9], s=b[10] << 8 | b[11], pc=b[12] << 8 | b[13])


def set_regs(t, r):
    t.halt()
    raw = bytes([r["cc"], r["a"], r["b"], r["dp"], r["x"] >> 8, r["x"] & 255, r["y"] >> 8, r["y"] & 255,
                 r["u"] >> 8, r["u"] & 255, r["s"] >> 8, r["s"] & 255, r["pc"] >> 8, r["pc"] & 255])
    t.s.sendall(pkt(b"G" + raw.hex().encode()))
    recv_reply(t.s)


def u8(t, name, off=0):
    return t.read(S[name] + off, 1)[0]


def boot(img, settle):
    port = 20000 + random.randrange(40000)
    proc = subprocess.Popen(
        ["xroar", "-ui", "null", "-machine", "coco2bus", "-rompath", str(ROOT / "source/roms"),
         "-bas", "BASIC.ROM", "-extbas", "EXTBASIC.ROM", "-cart", "rsdos", "-cart-type", "rsdos",
         "-cart-rom", "DSKBASIC.ROM", "-load-fd0", str(img), "-no-ratelimit", "-timeout", "3000",
         "-type", 'LOADM"DIZZY":EXEC\r', "-gdb", "-gdb-port", str(port)],
        stdout=open("/tmp/quicksave_xroar.log", "w"), stderr=subprocess.STDOUT)
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
        raise OSError("gdb never came up")
    t.running = False
    return proc, t


def start_game(t):
    """the title is waiting for SPACE: jump to new_game instead (xroar halts on an instruction boundary: safe)."""
    mix_lo = S["TITLE_RAW_BUF"]
    for _ in range(6):
        t.run_for(0.4)
        pc = regs(t)["pc"]
        if mix_lo <= pc < mix_lo + S["TITLE_RAW_LEN"]:
            break
    else:
        raise TimeoutError("title never reached")
    r = regs(t)
    r.update(pc=S["new_game"], s=0x0100, cc=r["cc"] | 0x50, dp=0)
    set_regs(t, r)
    t.run_for(1.0)
    check("game started (room 36)", u8(t, "cur_room") == 36 and u8(t, "dizzy_y") != 0)


def unpatch_key(t):
    """the key press is over: put save_poll's first two bytes back (else every main-loop pass would 'press' the key again)"""
    t.write(S["save_poll"], ORIG_POLL)


ORIG_POLL = b"\xc6\xf7"                 # ldb #SV_KEY_S


def patch_key(t, target):
    a = S["save_poll"]
    rel = S[target] - (a + 2)
    assert -128 <= rel < 128, rel
    t.write(a, bytes([0x20, rel & 255]))                  # bra target
    t.write(S["msg_wait_dismiss"], bytes([0x39]))         # rts: "SPACE pressed"


def phase(img, which, settle, markers=None):
    proc, t = boot(img, settle)
    try:
        start_game(t)
        out = {}
        if which == "save":
            t.write(S["coins"], bytes([7]))
            t.write(S["lives"], bytes([1]))
            t.write(S["inv"], bytes([0x11]))
            t.write(S["actor_ram"] + 8 * 3 + 3, bytes([0x66]))
            t.write(S["respawn_x"], bytes([0x58]))
            t.run_for(0.5)
            patch_key(t, "sp_save")
            for _ in range(60):
                t.run_for(0.3)
                if u8(t, "sv_code") != 0xFF:
                    unpatch_key(t)
                    break
            out["code"] = u8(t, "sv_code")
        else:
            before = (u8(t, "coins"), u8(t, "lives"))
            patch_key(t, "sv_do_load")
            for _ in range(60):
                t.run_for(0.3)
                if u8(t, "sv_code") not in (0xFF,):
                    unpatch_key(t)
                    break
            t.run_for(1.5)
            out["code"] = u8(t, "sv_code")
            out["before"] = before
            out["markers"] = (u8(t, "coins"), u8(t, "lives"), u8(t, "inv"), u8(t, "actor_ram", 8 * 3 + 3), u8(t, "respawn_x"))
            p0 = u8(t, "rng_ctr")
            seen = {p0}
            for _ in range(8):
                t.run_for(0.1)
                seen.add(u8(t, "rng_ctr"))
            out["running"] = len(seen) > 1
        t.cont()
        time.sleep(0.2)
        t.s.close()
    except BaseException:
        proc.terminate()                 # a failed attempt must not keep running for its whole emulated timeout
        proc.wait(10)
        raise
    try:
        proc.wait(200)                   # clean exit at -timeout: that is what flushes the write-back disk
    except subprocess.TimeoutExpired:
        proc.terminate()
    return out


def run_phase(img, which):
    for settle in (3.0, 4.0, 5.0, 3.5, 4.5):
        try:
            return phase(img, which, settle)
        except (TimeoutError, OSError, BrokenPipeError) as e:
            print(f"  (gdb {type(e).__name__} at settle {settle}: retrying)", flush=True)
    raise SystemExit("QSXR FAIL gdb never behaved")


def main():
    tmp = Path(tempfile.mkdtemp())
    img = tmp / "dizzy_qs.dsk"
    shutil.copy(DSK, img)
    o = run_phase(img, "save")
    check("phase 1: S -> sv_code 0 (saved) in the REAL boot", o["code"] == 0, f"code={o['code']}")
    sav = subprocess.check_output([str(DSKW), "extract", str(img), "DIZZY.SAV", "/dev/stdout"])
    check("host image after xroar's clean exit holds a DZSV header", sav[:4] == b"DZSV", sav[:16].hex())
    subprocess.check_call([str(DSKW), "check", str(img)], stdout=subprocess.DEVNULL)
    check("the disk image still passes dskwriter check (directory + FAT intact)", True)
    o = run_phase(img, "load")
    check("phase 2: after a fresh boot of that disk, L restored the markers (coins 7, lives 1, inv 0x11, actor byte 0x66, respawn_x 0x58)",
          o["markers"] == (7, 1, 0x11, 0x66, 0x58) and o["code"] in (10, 20), f"before={o['before']} after={o['markers']} code={o['code']}")
    check("the game keeps running after the load (rng_ctr advances)", o["running"])
    o = run_phase(DSK, "load")
    check("phase 3: the pristine disk (empty slot): L -> code 1, nothing restored", o["code"] == 1 and o["markers"][0] == o["before"][0], f"code={o['code']}")
    print("QSXR SUMMARY fail=%d" % fails)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
