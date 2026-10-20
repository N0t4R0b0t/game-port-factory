#!/usr/bin/env python3
"""tools/floppy_state_check.py -- T0242: the quick-save STATE SET manifest vs the evidence.

target/floppy_state.txt classifies RAM:   S sym[+off] len   = SAVED          T sym[+off] len = deliberately NOT saved
(transient / derived by load_room+force_redraw / hardware / cosmetic), each with a reason.  This checks, hard:
  * every static write site found by tools/state_set.py (target/floppy/state_static.json, widths included) lies
    entirely inside S or T ranges  -> a store the manifest does not know about FAILS the build;
  * every byte that CHANGED between two playthrough checkpoints (harness/floppy_state_dyn.lua ->
    target/floppy/state_dyn.txt) lies inside S or T ranges (skipped with --no-dyn / when the file is absent);
  * no S range overlaps a T range, S ranges lie in RAM the loader fills (not framebuffers/scratch);
and emits  target/floppy/state_ranges.asm  = the merged S ranges as `fdb start,len` pairs + STATE_LEN, which
the save/load overlay (target/floppy_save.asm) walks (state_table.asm = the pairs, state_ranges.asm = the equates).
Usage: tools/floppy_state_check.py [--no-dyn] [--list]       exit 0 = complete
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "target/floppy"


def rdmap(p):
    d = {}
    for l in Path(p).read_text().splitlines():
        m = re.match(r"^Symbol: (\S+) \(.*?\) = ([0-9A-Fa-f]+)$", l)
        if m:
            d[m.group(1)] = int(m.group(2), 16)
    return d


F = rdmap(ROOT / "target/room36_floppy.map")
R = rdmap(OUT / "state_raw.map") if (OUT / "state_raw.map").exists() else {}
SYM = dict({k: v for k, v in R.items() if v >= F.get("CODE_DEST", 0xE5D6)})
SYM.update(F)


def addr(expr):
    if re.fullmatch(r"\$[0-9A-Fa-f]+", expr):
        return int(expr[1:], 16)
    m = re.fullmatch(r"([A-Za-z_]\w*)(?:([+-])(\d+|\$[0-9A-Fa-f]+))?", expr)
    if not m or m.group(1) not in SYM:
        sys.exit(f"floppy_state.txt: unknown symbol in {expr!r}")
    off = m.group(3)
    v = int(off.lstrip("$"), 16 if off.startswith("$") else 10) if off else 0
    return SYM[m.group(1)] + (-v if m.group(2) == "-" else v)


rows = []
for n, l in enumerate((ROOT / "target/floppy_state.txt").read_text().splitlines(), 1):
    t = l.split("#")[0].split()
    if not t:
        continue
    if t[0] not in ("S", "T") or len(t) != 3:
        sys.exit(f"floppy_state.txt:{n}: bad line {l!r}")
    a = addr(t[1])
    ln = int(t[2], 0) if not t[2].isalpha() else None
    rows.append((t[0], a, int(t[2], 0), t[1], l.split("#", 1)[1].strip() if "#" in l else ""))

# table sizes are tied to the build's own counts (a grown table must grow the S line, or this fails)
SIZES = {"actor_init_tape": ("ACTOR_COUNT_tape", "ACTOR_STRIDE_tape"), "coin_init_tape": ("COIN_COUNT_tape", "COIN_STRIDE_tape")}
for k, a, ln, nm, why in rows:
    if k == "S" and nm in SIZES:
        want = SYM[SIZES[nm][0]] * SYM[SIZES[nm][1]]
        if ln != want:
            sys.exit(f"floppy_state.txt: S {nm} is {ln} bytes but the table is {SIZES[nm][0]} x {SIZES[nm][1]} = {want}")
# actor_ram + coin_ram live inside the S line that starts at ai_n / croc_var_a: check they are covered whole
need = [("actor_ram", SYM["ACTOR_COUNT"] * SYM["ACTOR_STRIDE"]), ("coin_ram", SYM["COIN_COUNT"] * SYM["COIN_STRIDE"]), ("inv", 4), ("respawn_room", 3)]
cov = {}
for k, a, ln, nm, why in rows:
    for x in range(a, a + ln):
        if x in cov and cov[x][0] != k:
            sys.exit(f"floppy_state.txt: ${x:04X} is both S and T ({nm})")
        cov[x] = (k, nm)
for nm, ln in need:
    for x in range(SYM[nm], SYM[nm] + ln):
        if cov.get(x, ("", ""))[0] != "S":
            sys.exit(f"floppy_state.txt: {nm}+{x - SYM[nm]} (a {ln}-byte state table) is not in an S range")
bad = []
for a, w, loc in json.load(open(OUT / "state_static.json"))["writes"]:
    if a < 0x100 or a >= 0xFF00:
        continue                                   # hidden-page DP offsets / I/O page
    for x in range(a, a + w):
        if x not in cov:
            bad.append((x, f"static write at {loc}"))
dynf = OUT / "state_dyn.txt"
if "--no-dyn" not in sys.argv and dynf.exists():
    for l in dynf.read_text().splitlines():
        x = int(l.split()[0], 16)
        if 0x4000 <= x < 0x5800 or 0x6000 <= x < 0x7800 or x >= 0xF2AE:
            continue                               # framebuffers; the TITLE_RAW_BUF scratch chain
        if x not in cov:
            bad.append((x, f"changed between checkpoints (x{l.split()[1]})"))
if bad and "--propose" in sys.argv:
    import bisect
    ss = sorted((v, k) for k, v in SYM.items())
    aa = [a for a, _ in ss]
    rules = [
        (r"^(ui_|bd_)", "banner/UI draw state: draw_ui repaints from lives/coins/room"),
        (r"^(ti_|lz_)", "title/unpack scratch"),
        (r"^(dd_|dc_|sp_|cb_|clr_|blit_|bm|bmr|rat_sv_|nib_|pt_|cw_|placeptr|win_top|new_col|old_col|dmg_|pre_y|old_dizzy|ast_|bsa_|n_solid|solid_list|gate_col_hdr|rope_col_hdr)", "per-pass / per-draw temporaries, rewritten before every use"),
        (r"^(draw_base|cur_buf|field_ctr|buf[AB]_last|fb_flip|rat_lastx|gate_last|flame_var|fire_var|flame_spr)", "draw machinery bound to the LIVE hardware page / per-buffer caches: force_redraw resets them, never restore"),
        (r"^(rt_|room_|keyflags)", "room geometry pointers rebuilt by load_room / transition temps / keys"),
        (r"^FD_", "disk driver NMI hook"),
    ]
    groups = []
    for x in sorted(set(b[0] for b in bad)):
        sy = ss[bisect.bisect_right(aa, x) - 1]
        why = next((r for p, r in rules if re.match(p, sy[1])), "??")
        if groups and groups[-1][1] == x and groups[-1][3] == why:
            groups[-1][1] = x + 1
        else:
            groups.append([x, x + 1, sy, why])
    for lo, hi, sy, why in groups:
        print(f"T {sy[1]}{'+%d' % (lo - sy[0]) if lo != sy[0] else ''} {hi - lo}  # {why}")
    sys.exit(1)
if bad:
    import bisect
    ss = sorted((v, k) for k, v in SYM.items())
    aa = [a for a, _ in ss]
    seen = set()
    print("UNCLASSIFIED (add S or T lines to target/floppy_state.txt):")
    for x, why in sorted(bad):
        s = ss[bisect.bisect_right(aa, x) - 1]
        key = (s[1])
        if key in seen:
            continue
        seen.add(key)
        print(f"  ${x:04X} {s[1]}+{x - s[0]}  ({why})")
    sys.exit(1)
# merged S ranges
s_bytes = sorted(x for x, (k, _) in cov.items() if k == "S")
rng = []
for x in s_bytes:
    if rng and x == rng[-1][1]:
        rng[-1][1] = x + 1
    else:
        rng.append([x, x + 1])
for lo, hi in rng:
    if 0x4000 <= lo < 0x5800 or 0x6000 <= lo < 0x7800 or hi > 0xF2AE or lo < 0x100:
        sys.exit(f"S range ${lo:04X}-${hi:04X} is in a framebuffer/scratch/low area")
total = sum(hi - lo for lo, hi in rng)
lines = ["; Generated by tools/floppy_state_check.py from target/floppy_state.txt -- do not edit.",
         f"STATE_NRANGES equ {len(rng)}", f"STATE_LEN equ {total}"]
tab = ["; Generated by tools/floppy_state_check.py -- do not edit.", "state_ranges"]
tab += [f"        fdb ${lo:04x},{hi - lo}" for lo, hi in rng]
(OUT / "state_table.asm").write_text("\n".join(tab) + "\n")
(OUT / "state_ranges.asm").write_text("\n".join(lines) + "\n")
print(f"floppy_state_check: COMPLETE -- {len(rows)} manifest lines, {len(rng)} merged S ranges, {total} bytes saved "
      f"(+16 header = {total + 16} B = {(total + 16 + 255) // 256} sectors)")
if "--list" in sys.argv:
    for lo, hi in rng:
        print(f"  ${lo:04X}-${hi - 1:04X} {hi - lo:4d}")
