#!/usr/bin/env python3
"""tools/state_set.py -- T0242: derive the quick-save STATE SET systematically (static half).

Reads the lwasm listings of the FLOPPY build (final pass for everything, RAW pass for block D, which the
final pass only includebin's) and the two maps.  Every instruction that WRITES memory through a named
operand (sta/stb/std/stx/sty/stu/sts and the read-modify-writes clr/inc/dec/neg/com/lsl/lsr/asl/asr/rol/ror)
is a write site; the written address is symbol+offset, or, for `sym,x` style operands, the table that
starts at sym.  Writes through plain pointers (`,x` `n,y` ...) are listed separately as POINTER writes
(their targets are tables whose bases are taken with ldx/ldy/leax #sym: listed as POINTER BASES).
Output (stdout): tab-separated rows  addr  size  symbol  kind  file:line(first) nsites , plus summaries.
Usage: tools/state_set.py [--json OUT]   (needs /tmp-free: regenerates the listings into target/floppy/)
"""
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "target/floppy"
COMMON = ["-DTITLE_MIX3=1", "-DDEBUG_XY=0", "-DHCLIP=1",
          "-DINF_LIVES=0", "-DTAPE_ROOMS=1", "-DFLOPPY=1", "-DSTART_ROOM=36"]


def lw(flags, name):
    lst, mp = OUT / f"{name}.lst", OUT / f"{name}.map"
    subprocess.run(["lwasm", "--decb", *COMMON, *flags, "-o", f"target/floppy/{name}.bin", f"--map=target/floppy/{name}.map",
                    f"--list=target/floppy/{name}.lst", "target/room36.asm"], check=True, cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return lst, mp


def symbols(mp):
    d = {}
    for l in Path(mp).read_text().splitlines():
        m = re.match(r"^Symbol: (\S+) \(.*?\) = ([0-9A-Fa-f]+)$", l)
        if m:
            d[m.group(1)] = int(m.group(2), 16)
    return d


WR = {"sta", "stb", "std", "stx", "sty", "stu", "sts", "clr", "clra", "inc", "dec", "neg", "com", "lsl", "lsr", "asl", "asr", "rol", "ror"}
WR_MEM = {"sta", "stb", "std", "stx", "sty", "stu", "sts", "clr", "inc", "dec", "neg", "com", "lsl", "lsr", "asl", "asr", "rol", "ror"}
LINE = re.compile(r"^([0-9A-F]{4}) ((?:[0-9A-F]{2})*)\s+\(\s*(\S+)\):(\d+)\s(.*)$")
FINAL_STAGE = OUT / "state_final"
if __name__ == "__main__":
    OUT.mkdir(exist_ok=True)
    fl, fm = lw(["-DSTAGE_LZ=1"], "state_final")
    rl, rm = lw(["-DSTAGE_GEN=1"], "state_raw")
    S = symbols(fm)
    SR = symbols(rm)
    code_dest = S["CODE_DEST"]
    allsym = dict(SR)
    allsym.update(S)
    byaddr = sorted((v, k) for k, v in allsym.items())
    import bisect
    addrs = [a for a, _ in byaddr]

    def sym_of(a):
        i = bisect.bisect_right(addrs, a) - 1
        return byaddr[i] if i >= 0 else (0, "?")

    def size_after(a):
        i = bisect.bisect_right(addrs, a)
        return (addrs[i] - a) if i < len(addrs) else 1

    sites = {}     # addr -> [loc,...]
    tables = {}    # base addr -> locs (indexed with a symbol base)
    ptrbases = {}  # sym -> locs  (ldx/ldy/leax #sym or sym,pcr)
    widths = {}
    ptrwrites = 0

    def eval_expr(e, table):
        e = e.strip().lstrip("<>")
        if not e:
            return None
        e2 = re.sub(r"\$([0-9A-Fa-f]+)", lambda m: str(int(m.group(1), 16)), e)
        e2 = re.sub(r"[A-Za-z_][A-Za-z_0-9]*", lambda m: str(table[m.group(0)]) if m.group(0) in table else "@@", e2)
        if "@@" in e2:
            return None
        try:
            return int(eval(e2.replace("/", "//"), {"__builtins__": {}}))
        except Exception:
            return None

    def scan(lst, table, lo, hi):
        global ptrwrites
        for l in Path(lst).read_text(errors="replace").splitlines():
            m = LINE.match(l)
            if not m:
                continue
            pc, byts, f, ln, src = int(m.group(1), 16), m.group(2), m.group(3), m.group(4), m.group(5)
            if not byts or not (lo <= pc < hi):
                continue
            src = src.split(";")[0].rstrip()
            toks = src.split()
            if not toks:
                continue
            if not src[0].isspace() and len(toks) > 1:
                toks = toks[1:]
            elif not src[0].isspace():
                continue
            mn = toks[0].lower()
            op = toks[1] if len(toks) > 1 else ""
            loc = f"{f}:{ln}"
            if mn in ("ldx", "ldy", "ldu", "ldd") and op.startswith("#"):
                v = eval_expr(op[1:], table)
                if v is not None:
                    ptrbases.setdefault(v, []).append(loc)
                continue
            if mn in ("leax", "leay", "leau") and re.match(r"^[A-Za-z_]\w*(\+\d+)?,pcr$", op):
                v = eval_expr(op[:-4], table)
                if v is not None:
                    ptrbases.setdefault(v, []).append(loc)
                continue
            if mn not in WR_MEM or not op:
                continue
            if op.startswith("["):
                ptrwrites += 1
                continue
            mi = re.match(r"^(.*),([xyus]|pcr)$", op)
            if mi:
                base = mi.group(1)
                if base == "" or re.fullmatch(r"-?\d+|[abd]|\$[0-9A-Fa-f]+|[+-]*\d*", base):
                    ptrwrites += 1
                    continue
                v = eval_expr(base, table)
                if v is None:
                    ptrwrites += 1
                else:
                    tables.setdefault(v, []).append(loc)
                continue
            if mn in ("clr", "inc", "dec", "neg", "com", "lsl", "lsr", "asl", "asr", "rol", "ror") and op in ("a", "b", "d"):
                continue
            v = eval_expr(op, table)
            if v is not None:
                sites.setdefault(v, []).append(loc)
                widths[v] = max(widths.get(v, 1), 2 if mn in ("std", "stx", "sty", "stu", "sts") else 1)

    scan(fl, allsym, 0x0100, code_dest)
    scan(rl, allsym, code_dest, 0xFF00)
    rows = []
    for a, locs in sorted(sites.items()):
        s = sym_of(a)
        rows.append((a, "direct", s[1], a - s[0], locs))
    for a, locs in sorted(tables.items()):
        s = sym_of(a)
        rows.append((a, "table", s[1], a - s[0], locs))
    res = {"direct": {hex(a): [s, off, len(locs), locs[0]] for a, k, s, off, locs in rows if k == "direct"},
           "table": {hex(a): [s, off, len(locs), locs[0]] for a, k, s, off, locs in rows if k == "table"},
           "ptrbase": {hex(a): [sym_of(a)[1], locs[0]] for a, locs in sorted(ptrbases.items())},
           "pointer_writes_unresolved": ptrwrites,
           "writes": [[a, widths.get(a, 1), locs[0]] for a, locs in sorted(sites.items())]}
    if "--json" in sys.argv:
        Path(sys.argv[sys.argv.index("--json") + 1]).write_text(json.dumps(res, indent=1))
    print(f"direct write targets {len(res['direct'])}, indexed-table bases {len(res['table'])}, pointer bases {len(res['ptrbase'])}, unresolved pointer writes {ptrwrites}")
