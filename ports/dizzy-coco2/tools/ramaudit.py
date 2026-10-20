#!/usr/bin/env python3
"""Runtime RAM audit of the TAPE build: where do the bytes of $0000-$FEFF live
DURING GAMEPLAY after boot, and which of them are slack?

Companion to memaudit.py (which audits LOAD-time regions of the -run image).
This one answers a different question -- "what is each address FOR once boot
has finished" -- and classifies every byte of $0000-$FEFF:

  code/data-live     needed throughout gameplay
  boot-only          loaded (or executed) at boot, dead once boot finishes (since T0224 no title
                     holes: blocks C/D are raw segments)
  title-reused       dead during play but needed again when the title is
                     re-shown after game over (gp_ud_gameover, TAPE_ROOMS)
  framebuffer        $4000-$57FF and $6000-$77FF (double-buffered PMODE4)
  transient-scratch  overlays / dedicated scratch whose contents never need to
                     survive (CUR_ROOM_CMASK, MIX3_BUF, ROOM_UNPACK_BUF ...)
  stack              $0000-$00FF
  FREE               not loaded and not referenced

Ground truth used:
  * the DECB segments of target/room36_tape.bin (what the tape LOADS where)
  * `Symbol: NAME (file) = HEX` lines of target/room36_tape.map
  * `; hole at $ADDR: using N of M bytes` comments of target/title_lz_tape.asm (paired with their
    title_lzN labels), and the STAGE1 file header at the head of target/room36.cas
  * comments in room36.asm / boot_code.asm / logic_low.asm / tape_stage1.asm,
    cited per row as file:line (looked up by regex at run time, so a citation
    that goes stale fails the script instead of lying).

Read-only: reads target/*, writes nothing unless --out is given.
Run from anywhere:  tools/ramaudit.py [--out FILE]
Exit 0 = table sums to exactly 65280 bytes, has no gap/overlap, and every
loaded byte lies in a non-FREE range.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
T = ROOT / "target"
# T0241: --floppy audits the FLOPPY build (target/room36_floppy.bin/.map) instead: same model, with the disk
# driver + overlay loader where TITLE_RESIDENT_LZ was and the floppy loader (target/floppy/loader.map) as
# "stage 1".  Without the flag nothing changes.
FLOPPY = "--floppy" in sys.argv
BIN = T / ("room36_floppy.bin" if FLOPPY else "room36_tape.bin")
MAP = T / ("room36_floppy.map" if FLOPPY else "room36_tape.map")
HOLES = T / ("title_lz_floppy.asm" if FLOPPY else "title_lz_tape.asm")
CAS = T / "room36.cas"
LOADER_MAP = T / "floppy" / "loader.map"
SRC = {
    "room36": T / "room36.asm",
    "boot": T / "boot_code.asm",
    "logic": T / "logic_low.asm",
    "stage1": T / ("floppy_stage1.asm" if FLOPPY else "tape_stage1.asm"),
    "holes": HOLES,
    "ramaudit-note": None,
}
LIMIT = 0xFF00

CLASSES = ["code/data-live", "boot-only", "title-reused", "framebuffer",
           "transient-scratch", "stack", "io/rom-vectors", "FREE"]


# ---------------------------------------------------------------- inputs
def decb_segments(path):
    d = path.read_bytes()
    pos, out = 0, []
    while pos < len(d) and d[pos] == 0:
        ln = (d[pos + 1] << 8) | d[pos + 2]
        ad = (d[pos + 3] << 8) | d[pos + 4]
        out.append((ad, ad + ln))
        pos += 5 + ln
    assert d[pos] == 0xFF, "DECB image not terminated by $FF"
    return out


def read_map(path):
    sy = {}
    for line in path.read_text().splitlines():
        m = re.match(r"Symbol: (\S+) \((.*?)\) = ([0-9A-Fa-f]+)", line)
        if m:
            sy[m.group(1)] = int(m.group(3), 16)
    return sy


def read_holes(path):
    """[(label, addr, used, cap)] in file order, from the mktitle comments:
         ; hole at $ADDR: using N of M bytes   (followed by `title_lzN` label)"""
    txt = path.read_text()
    out = []
    for m in re.finditer(r"; hole at \$([0-9a-fA-F]+): using (\d+) of (\d+) bytes"
                         r"(?:.*?\n)*?(title_lz\d+)\n", txt):
        out.append((m.group(4), int(m.group(1), 16), int(m.group(2)), int(m.group(3))))
    n = len(re.findall(r"; hole at \$", txt))
    assert n == len(out), "ramaudit: could not pair every `hole at` comment with a title_lzN label"
    return out


def read_stage1(cas):
    """(load_addr, length) of the STAGE1 file at the head of the .cas, or None.
    CoCo cassette: 55 3C type len data... sum. type 0 = namefile block
    (name[8], type, ascii, gap, exec16, load16), type 1 = data, 255 = EOF."""
    if not cas.exists():
        return None
    d = cas.read_bytes()
    i = d.find(b"\x55\x3c\x00")
    if i < 0:
        return None
    ln = d[i + 3]
    h = d[i + 4:i + 4 + ln]
    load = (h[13] << 8) | h[14]
    i += 4 + ln + 1
    size = 0
    while True:
        j = d.find(b"\x55\x3c", i)
        if j < 0 or d[j + 2] != 1:
            break
        size += d[j + 3]
        i = j + 4 + d[j + 3] + 1
    return load, size


def equ_names():
    """names defined with `equ` anywhere in target/*.asm: constants that merely LOOK like an
    address (CODE_BUDGET=$0D00, TITLE_RAW_LEN ...) must not count as labels inside a FREE row."""
    out = set()
    for f in T.glob("*.asm"):
        for m in re.finditer(r"^(\w+)\s+equ\b", f.read_text(errors="replace"), re.M):
            out.add(m.group(1))
    return out


SEGS = decb_segments(BIN)
EQU_NAMES = equ_names()
SYM = read_map(MAP)
HOLE = read_holes(HOLES)
def read_loader_span(mp):
    """(org, length) of the floppy loader from its own map (floppy_boot .. LOADER_END), or None."""
    if not mp.exists():
        return None
    sy = read_map(mp)
    if "floppy_boot" not in sy or "LOADER_END" not in sy:
        return None
    return sy["floppy_boot"], sy["LOADER_END"] - sy["floppy_boot"]


STAGE1 = read_loader_span(LOADER_MAP) if FLOPPY else read_stage1(CAS)
_src_cache = {}


def cite(key, regex, nth=0):
    """file:line of the nth line in SRC[key] matching regex. Fails loudly."""
    p = SRC[key]
    if p not in _src_cache:
        _src_cache[p] = p.read_text().splitlines()
    hits = [i + 1 for i, l in enumerate(_src_cache[p]) if re.search(regex, l)]
    if len(hits) <= nth:
        sys.exit(f"ramaudit: stale citation, /{regex}/ not found in {p.name}")
    return f"{p.name}:{hits[nth]}"


def S(name, off=0):
    if name not in SYM:
        sys.exit(f"ramaudit: symbol {name} missing from {MAP.name}")
    return SYM[name] + off


def seg_end_at(addr):
    """end of the DECB segment that starts exactly at addr (None if none)."""
    for a, b in SEGS:
        if a == addr:
            return b
    return None


def loaded_in(lo, hi):
    return sum(max(0, min(hi, sb) - max(lo, sa)) for sa, sb in SEGS)


def loaded_top(lo, hi):
    """highest loaded address+1 inside [lo,hi), or lo if nothing is loaded."""
    t = lo
    for sa, sb in SEGS:
        if sa < hi and sb > lo:
            t = max(t, min(sb, hi))
    return t


# ---------------------------------------------------------------- the model
R = []   # (lo, hi, owner, class, evidence, reuse-note)


def add(lo, hi, owner, cls, ev, need=""):
    assert cls in CLASSES, cls
    assert hi > lo, (owner, hex(lo), hex(hi))
    R.append((lo, hi, owner, cls, ev, need))


def add_opt(lo, hi, *a):
    """like add, but an empty span (hi == lo) is simply not a row."""
    assert hi >= lo, (a[0], hex(lo), hex(hi))
    if hi > lo:
        add(lo, hi, *a)


def region(tag, start_sym, end_sym, slot_end_sym, owner, ev_regex, extra=""):
    """A persistent TAPE_LOW region: [start, slot_end) content, [slot_end, end) free tail.
    The content/tail split is DERIVED, then cross-checked against the loaded
    DECB segments (loaded top inside the region must equal the slot end)."""
    lo, hi, se = S(start_sym), S(end_sym), S(slot_end_sym)
    assert lo <= se <= hi, (tag, hex(lo), hex(se), hex(hi))
    top = loaded_top(lo, hi)
    assert top == se, f"{tag}: loaded top {top:04X} != slot end {se:04X}"
    add_opt(lo, se, f"{tag} content: {owner}", "code/data-live", cite("room36", ev_regex), extra)
    add_opt(se, hi, f"{tag} free tail (persistent, not loaded, not written by boot or play)", "FREE",
            cite("room36", ev_regex),
            "free at load and at run: a direct (<$8000) tape segment may target it")


LOW_END = S("low_region_end")
START = S("start")

# --- title holes: since T0224 the tape build has NONE (blocks C/D are raw tape segments
# at RC_DEST/CODE_DEST, the title stream is only TITLE_RESIDENT_LZ). Anything that
# reappears must be modelled deliberately, so fail loudly instead of mis-classifying it.
if HOLE:
    sys.exit("ramaudit: title_lz_tape.asm has holes again (" + ", ".join(h[0] for h in HOLE) +
             ") -- the model assumes none since T0224; extend it")
for gone in ("title_lz0", "title_lz1", "title_frags", "unpack_c", "unpack_d", "TAPE_LOW3_HOLE_START"):
    if gone in SYM:
        sys.exit(f"ramaudit: symbol {gone} exists again -- tape build was assumed hole/gather-free (T0224)")

# --- $0000-$00FF: stack
add(0x0000, 0x0100, "stack ($0100 grows down); NO direct-page vars (no `<` operands, no setdp)",
    "stack", cite("room36", r"^\s+lds #\$0100"),
    "peak depth UNMEASURED; any shrink needs a sentinel-fill high-water harness")

# --- $0100-low_region_end: room36 data, messages, ui, lz, title/boot code
add(0x0100, S("r35_room_place_count"), "room36 data (r36_*)", "code/data-live",
    cite("room36", r"^\s+org \$0100"))
add(S("r35_room_place_count"), S("msg_foundcoin"), "room35 data (r35_*)", "code/data-live",
    cite("room36", r'include "room35_data.asm"'))
add(S("msg_foundcoin"), S("msgname_36"), "gap_messages.asm (msg_*)", "code/data-live",
    cite("room36", r'include "gap_messages.asm"'))
add(S("msgname_36"), S("draw_ui"), "ui_room_names.asm (msgname_*, room_name_table, find_room_name)",
    "code/data-live", cite("room36", r'include "ui_room_names.asm"'))
SEED = "seed_inventory" in SYM    # T0225b (L4): gated out of the tape build unless START_ITEMn is set
add(S("draw_ui"), S("seed_inventory") if SEED else S("lz_unpack"),
    "ui.asm (draw_ui, draw_border ...)", "code/data-live", cite("room36", r'include "ui.asm"'))
if SEED:
    add(S("seed_inventory"), S("lz_unpack"),
        "seed_inventory/si_find/si_items (START_ITEM test aid; present because START_ITEMn was set)",
        "code/data-live", cite("room36", r"jsr seed_inventory"))
add(S("lz_unpack"), S("ti_len"),
    "lz_unpack/lz_getbit/lz_gamma (reused: load_room unpacks every packed room)",
    "code/data-live", cite("room36", r"jsr lz_unpack", 2))
add(S("ti_len"), S("lz_rem"), "ti_len/ti_coln/ti_rown (vars of gather+transpose+resident copy)",
    "title-reused", cite("boot", r"^ti_len"))
add(S("lz_rem"), S("show_title"), "lz_rem/lz_dist/lz_bits/lz_state (lz_unpack vars)",
    "code/data-live", cite("boot", r"^lz_rem"))
add(S("show_title"), S("ti_transpose"),
    "show_title: copy resident prefix + title/mixer unpack (no gather, no unpack_c/d in the tape build)",
    "boot-only", cite("boot", r"^show_title$"),
    "runs once from start:. Replay enters at ti_transpose, not here")
add(S("ti_transpose"), S("show_title_resident"),
    "ti_transpose/ti_dup/ti_press/ti_release (title draw + wait)", "title-reused",
    cite("boot", r"T0231: ti_transpose"))
add(S("show_title_resident"), LOW_END,
    "show_title_resident + title_copy_resident (game-over / completedgame title replay)", "title-reused",
    cite("boot", r"T0231: show_title_resident"))

# --- TAPE_LOW_REGION4 [low_region_end, $0E00) (the old hole 0), then start:
region("TAPE_LOW_REGION4", "TAPE_LOW4_START", "TAPE_LOW4_END", "tape_low4_slot_end",
       "(empty slot)", r"^tape_low4_slot_start")
new_game = S("new_game")
# T0225b (L3): `start` left $0E00 for the spare tail of framebuffer A; new_game owns $0E00 now.
assert S("TAPE_LOW4_START") == LOW_END and S("TAPE_LOW4_END") == new_game == 0x0E00
START_END = S("tape_start_end")

# --- resident code+data new_game .. code_data_end (incl. unloaded rmb gaps = live bss)
cde = S("code_data_end")
assert cde == S("TAPE_LOW3_START"), (hex(cde), hex(S("TAPE_LOW3_START")))
gaps = []
p = new_game
for sa, sb in sorted(SEGS):
    if sb <= new_game or sa >= cde:
        continue
    if sa > p:
        gaps.append((p, sa))
    p = max(p, sb)
if p < cde:
    gaps.append((p, cde))
add(new_game, cde,
    "resident code+data: new_game..item_name_tab (incl. rmb bss: solid_list, blit_revbuf, rat_sv_*, "
    "inv, actor_ram, coin_ram)", "code/data-live", cite("room36", r"^new_game"),
    "unloaded (bss) gaps inside: " + ", ".join(f"{x:04X}-{y - 1:04X}" for x, y in gaps))

# --- TAPE_LOW_REGION3 [code_data_end, $4000) (old hole 1 + its tail)
region("TAPE_LOW_REGION3", "TAPE_LOW3_START", "TAPE_LOW3_END", "tape_low3_slot_end",
       "T0223 shopkeeper/bean/beanstalk code+state+messages", r"^tape_low3_slot_start")
assert S("TAPE_LOW3_END") == 0x4000

# --- framebuffer A $4000-$57FF: staged block A at load, then the live page
fa_end = seg_end_at(0x4000)
assert fa_end is not None and 0x4000 < fa_end <= 0x5800, "no DECB segment at $4000 (staged block A)"
add(0x4000, fa_end, "FB A (load-time only: staged block A, packed; relocated to $8000+ at boot)",
    "framebuffer", cite("room36", r"T0058: staged at \$4000 -- inside framebuffer A"))
add_opt(fa_end, START, "FB A spare (not loaded; PMODE4 page, overwritten by the first draw)", "framebuffer",
        cite("room36", r"T0058: staged at \$4000 -- inside framebuffer A"))
# T0225b (L3): the tape build's start: lives here (a loaded DECB segment, the EXEC address). Boot-only:
# it ends in `jmp show_title`, whose transpose then overwrites the whole page.
assert seg_end_at(START) == START_END, "start: is not its own DECB segment"
assert fa_end <= START and START_END <= 0x5800
add(START, START_END,
    "start: SAM/PIA init + relocator + nibswap build + jmp show_title (tape EXEC); never re-entered",
    "boot-only", cite("room36", r"^TAPE_START_ORG"),
    "runs from the FB A spare tail; dead once show_title's ti_dup overwrites page A")
add_opt(START_END, 0x5800, "FB A spare after start: (not loaded; PMODE4 page)", "framebuffer",
        cite("room36", r"^TAPE_START_ORG"))

# --- gap1 $5800-$5FFF: live code, then TAPE_LOW_REGION2
g1 = S("gap1_end")
assert S("TAPE_LOW2_START") == g1
add(0x5800, S("prtmessage"), "dizzy_frame36-38 tail + tables (dizzy_frames_tail.asm)", "code/data-live",
    cite("room36", r'include "dizzy_frames_tail.asm"'))
add(S("prtmessage"), g1, "message VM + DTE + draw_box + msg vars (message.asm)", "code/data-live",
    cite("room36", r'include "message.asm"'))
region("TAPE_LOW_REGION2", "TAPE_LOW2_START", "TAPE_LOW2_END", "tape_low2_slot_end",
       "T0221 completion tune (win_mix3, LZ)", r"^tape_low2_slot_start")
assert S("TAPE_LOW2_END") == 0x6000

# --- framebuffer B $6000-$77FF: staged block B, then (derived) stage1, then spare
fb_end = seg_end_at(0x6000)
assert fb_end is not None and 0x6000 < fb_end <= 0x7800, "no DECB segment at $6000 (staged block B)"
add(0x6000, fb_end, "FB B (load-time only: staged block B, packed; later title-unpack scratch + FB)",
    "framebuffer", cite("room36", r"org \$6000", 0))
p = fb_end
if STAGE1:
    s1, sl = STAGE1
    if 0x6000 <= s1 < 0x7800:
        assert s1 >= p and s1 + sl <= 0x7800, f"stage1 ${s1:04X}+{sl} does not fit FB B spare"
        add_opt(p, s1, "FB B spare (not loaded)", "framebuffer", cite("room36", r"org \$6000", 0))
        add(s1, s1 + sl, ("floppy_stage1 loader DIZZY.BIN (code + segment table; dead after hand-off)" if FLOPPY else
                          "tape_stage1 loader (code + scratch; first file on the tape, dead after hand-off)"),
            "framebuffer", cite("stage1", r"^LOADER_END" if FLOPPY else r"^STAGE1_END"),
            ("placed by tools/floppy_pack.sh above block B's last (padded) sector; read here from target/floppy/loader.map" if FLOPPY else
             "placed by tools/tape_pack.sh into a window no tape segment writes; read here from the .cas header"))
        p = s1 + sl
add_opt(p, 0x7800, "FB B spare (not loaded; PMODE4 page, overwritten by the first draw)", "framebuffer",
        cite("room36", r"org \$6000", 0))

# --- gap2 $7800-$7FFF: logic_low (+ unpack_c/d), TAPE_LOW_REGION, nibswap, rat save-under
g2 = S("gap2_end")
assert S("TAPE_LOW_START") == g2
assert 0x7800 < g2
add(0x7800, g2, "logic_low.asm (lifts, well_route, ...)", "code/data-live",
    cite("room36", r"^\s+org \$7800"))
region("TAPE_LOW_REGION", "TAPE_LOW_START", "TAPE_LOW_END", "tape_low_slot_end",
       "T0219/T0220/T0221 tape code, messages (msg_data_tape_low, tape_win_code)", r"^tape_low_slot_start")
nib = S("nibswap")
assert nib == S("TAPE_LOW_END")
assert nib + 256 == 0x8000, "nibswap no longer ends at $8000 (T0225b: it fills the top of the gap)"
add(nib, 0x8000, "nibswap (built at boot by start:, read by every blit)", "code/data-live",
    cite("room36", r"^nibswap rmb 256"))

# --- $8000+: unpacked at boot from the staged blocks
r9, rc, ie = S("R9800_DEST"), S("RC_DEST"), S("IMAGE_END")
add(0x8000, r9, "block A unpacked at boot (rooms, sprites, frame_table, actor_data, dizzy body A)",
    "code/data-live", cite("room36", r"^r8000_staged_start"))
add(r9, rc, "block B unpacked at boot (rooms, shared overflow sprites, dizzy body B)", "code/data-live",
    cite("room36", r"^R9800_DEST"))
assert S("tape_c_raw_start") == rc and S("tape_c_raw_end") == ie
add(rc, ie, "block C RAW tape segment at RC_DEST (rooms 39+23; T0224: no longer unpacked)", "code/data-live",
    cite("room36", r"^RC_DEST"))

# --- tape-only region [IMAGE_END, CODE_DEST)
if FLOPPY:
    tr = S("fd_trk")
    assert tr == ie, (hex(tr), hex(ie))
    tl = S("floppy_code_end")
    add(tr, tl, "FLOPPY resident disk driver (target/disk_io.asm) + overlay loader/table + heart-demo stub + tune reblob (floppy_code.asm)",
        "code/data-live", cite("room36", r'include "floppy_code.asm"'),
        "replaces the 3266-byte TITLE_RESIDENT_LZ: the title stream is overlay OVL_TITLE on the disk")
else:
    tr = S("TITLE_RESIDENT_LZ")
    assert tr == ie
    tl = tr + S("TITLE_RESIDENT_LEN")
    add(tr, tl, "TITLE_RESIDENT_LZ: resident packed title+music copy (game-over replay AND boot prefix)",
        "title-reused", cite("room36", r'include "title_resident_lz.asm"'),
        "read at boot (title_copy_resident) and by every replay; NOT duplicated in the holes any more (T0219)")
ub = S("ROOM_UNPACK_BUF")
ue = ub + S("ROOM_UNPACK_BUF_LEN")
add(tl, ub, "tape actor/coin tables, msgs, tape_code (update_hawk/dragon40/log48/dozy)",
    "code/data-live", cite("room36", r'include "actor_data_tape.asm"'))
add(ub, ue, "ROOM_UNPACK_BUF (dedicated load_room unpack buffer, loaded as zeros)", "transient-scratch",
    cite("room36", r"^ROOM_UNPACK_BUF$"),
    "contents dead between room loads but permanently dedicated; shrinking needs ROOM_UNPACK_BUF_LEN lowered")
te, cd = S("tape_room_staged_end"), S("CODE_DEST")
assert ue <= te <= cd
add(ue, te, "tape-only rooms (74 ... 77) delivered raw", "code/data-live",
    cite("room36", r'include "room74_data.asm"'))
add_opt(te, cd, "tape-only region free span", "FREE", cite("room36", r"ifgt tape_room_staged_end-CODE_DEST"),
        "free at load and at run; contiguous with the tape region's end -> append rooms/data here")
ce = cd + S("TITLE_EXTRA2_RAW")
assert S("tape_d_raw_start") == cd and S("tape_d_raw_end") == ce
add(cd, ce, "block D RAW tape segment at CODE_DEST (update_dragon/croc/portcullis/rat/troll/armorog/lifts, font, sound)",
    "code/data-live", cite("room36", r"^\s+org CODE_DEST"))
add_opt(ce, S("BANNER_BUF"),
        "CODE_BUDGET slack: CODE_BUDGET - TITLE_EXTRA2_RAW (raw block D)",
        "FREE", cite("room36", r"^CODE_BUDGET   equ"),
        "raw block D is exactly TITLE_EXTRA2_RAW bytes, so a raw tape segment here survives. "
        "CODE_BUDGET is shared with -run, so only a TAPE_ROOMS-gated change may shrink it")

# --- TITLE_RAW_BUF overlay
tb = S("TITLE_RAW_BUF")
assert S("BANNER_BUF") == tb  # tape build: banner aliased, no resident banner
cm, at, ps, pb, se = (S("CUR_ROOM_CMASK"), S("ATTR_CELLS"), S("ROOM_PLACE_SORTED"),
                      S("ROOM_PLACE_BANDS"), S("T0163_SCRATCH_END"))
add(cm, at, "CUR_ROOM_CMASK (live in game, overlays MIX3 mixer blob)", "transient-scratch",
    cite("room36", r"^CUR_ROOM_CMASK equ"))
add(at, ps, "ATTR_CELLS (derive pass scratch inside load_room)", "transient-scratch",
    cite("room36", r"^ATTR_CELLS    equ"))
add(ps, se, "ROOM_PLACE_SORTED + ROOM_PLACE_BANDS (rebuilt every load_room)", "transient-scratch",
    cite("room36", r"^ROOM_PLACE_SORTED equ"))
# T0225b (L2'): rat/hawk/Dozy save-under buffers live in the title chain's gameplay-unused tail
rsv_end = S("RAT_SV_END")
assert rsv_end == S("rat_sv_buf_b") + S("RAT_SV_CAP") and S("rat_sv_hdr_a") == se and rsv_end <= LIMIT
add(se, rsv_end, "rat/hawk/Dozy save-under buffers (rat_sv_hdr_a..rat_sv_buf_b; hdr 5 + RAT_SV_CAP each)",
    "transient-scratch", cite("room36", r"^rat_sv_hdr_a equ"),
    "garbage-tolerant: new_game clears both valid bytes after every title run; redraw's 255 sentinel "
    "invalidates each slot before its first restore")
add_opt(rsv_end, LIMIT,
    "rest of TITLE_RAW_BUF: only the title mixer blob tail + MIX3_DP page ($FE00-$FEFF) use it",
    "transient-scratch", cite("room36", r"^MIX3_DP"),
    "unused during gameplay but CLOBBERED by every title replay (mixer unpacks into MIX3_BUF "
    "and runs with DP=$FE). Not persistent unless the replay mixer moves")

R.sort()


# ---------------------------------------------------------------- checks
def check():
    pos = 0
    for lo, hi, owner, cls, ev, need in R:
        assert lo == pos, f"gap/overlap at {pos:04X}: next row starts {lo:04X} ({owner})"
        pos = hi
    assert pos == LIMIT, f"table ends at {pos:04X}, not {LIMIT:04X}"
    total = sum(hi - lo for lo, hi, *_ in R)
    assert total == 65280, f"table sums to {total}, expected 65280"
    # every loaded byte must lie in a non-FREE range
    for sa, sb in SEGS:
        assert sb <= LIMIT, f"loaded block {sa:04X}-{sb:04X} reaches I/O page"
        for lo, hi, owner, cls, ev, need in R:
            if cls == "FREE" and lo < sb and sa < hi:
                raise AssertionError(f"loaded block {sa:04X}-{sb:04X} overlaps FREE range "
                                     f"{lo:04X}-{hi:04X} ({owner})")
    # no real LABEL may sit strictly inside a FREE range (`equ` constants are filtered out)
    for lo, hi, owner, cls, ev, need in R:
        if cls == "FREE":
            inside = sorted(n for n, v in SYM.items() if lo < v < hi and n not in EQU_NAMES)
            assert not inside, f"symbols inside FREE {lo:04X}-{hi:04X}: {inside}"
    # stage-1 loader runs WHILE the tape streams: no loaded segment may overlap it or its
    # zero-page vars ($7C-$81), and it must not sit in a persistent (live/FREE) range.
    if STAGE1:
        s1, sl = STAGE1
        for sa, sb in SEGS:
            assert not (sa < s1 + sl and s1 < sb), f"tape segment {sa:04X}-{sb:04X} overwrites stage1 {s1:04X}+{sl}"
            assert FLOPPY or not (sa < 0x82 and 0x7C < sb), f"tape segment {sa:04X}-{sb:04X} overwrites stage1 zero-page vars"
        for lo, hi, owner, cls, ev, need in R:
            if lo < s1 + sl and s1 < hi:
                assert cls == "framebuffer", f"stage1 overlaps persistent range {lo:04X}-{hi:04X} ({owner})"
    # every hole's declared use must equal what the map shows
    for lbl, a, used, cap in HOLE:
        assert S(lbl) == a
    return total


def main():
    out_path = None
    if "--out" in sys.argv:
        out_path = Path(sys.argv[sys.argv.index("--out") + 1])
    total = check()
    lines = []
    P = lines.append
    P(f"{'FLOPPY' if FLOPPY else 'TAPE'} build runtime RAM audit  (target/{BIN.name}, $0000-$FEFF)")
    P("DECB segments loaded: " + ", ".join(f"{a:04X}-{b - 1:04X}" for a, b in SEGS))
    P("")
    P(f"{'START':>5} {'END':>5} {'SIZE':>5} {'LOADED':>6}  {'CLASS':<17} OWNER  [evidence]")
    for lo, hi, owner, cls, ev, need in R:
        P(f"{lo:05X} {hi - 1:05X} {hi - lo:5d} {loaded_in(lo, hi):6d}  {cls:<17} {owner}  [{ev}]")
    P("")
    P("CLASS TOTALS")
    tot = {c: 0 for c in CLASSES}
    for lo, hi, owner, cls, ev, need in R:
        tot[cls] += hi - lo
    for c in CLASSES:
        P(f"  {c:<18}{tot[c]:6d}")
    P(f"  {'SUM':<18}{sum(tot.values()):6d}   (asserted == 65280, no gaps, every loaded byte non-FREE)")
    P("")
    P("SLACK >= 32 B (FREE or boot-only, framebuffers excluded) and transient-but-free-in-gameplay")
    for lo, hi, owner, cls, ev, need in R:
        if hi - lo >= 32 and (cls in ("FREE", "boot-only") or (cls == "transient-scratch" and lo >= se)):
            P(f"  {lo:04X}-{hi - 1:04X} {hi - lo:5d} B  {cls:<17} {owner}")
            P(f"        evidence: {ev}")
            if need:
                P(f"        reuse:    {need}")
    P("")
    P("Facts for the brief:")
    P(f"  title holes: none (T0224). blocks C ({S('TITLE_EXTRA_RAW')} B @ ${S('tape_c_raw_start'):04X}) and "
      f"D ({S('TITLE_EXTRA2_RAW')} B @ ${S('tape_d_raw_start'):04X}) are raw tape segments")
    if FLOPPY:
        P(f"  the title stream ({S('TITLE_RESIDENT_LEN')} B) is NOT resident: OVL_TITLE on the disk, read into TITLE_LZ_BUF at boot and at every replay")
    else:
        P(f"  TITLE_RESIDENT_LZ ({S('TITLE_RESIDENT_LEN')} B) == TITLE_LZ_LEN+TITLE_MUSIC_LEN = "
          f"{S('TITLE_LZ_LEN') + S('TITLE_MUSIC_LEN')}: boot copies it to TITLE_LZ_BUF; nothing is gathered")
    persist = sum(hi - lo for lo, hi, o, c, e, n in R if c == "FREE")
    P(f"  persistent FREE bytes (not loaded, not referenced, not framebuffer): {persist}")
    for lo, hi, o, c, e, n in R:
        if c == "FREE":
            P(f"    {lo:04X}-{hi - 1:04X} {hi - lo:4d}  {o}")
    if STAGE1:
        P(f"  {'floppy loader (from ' + LOADER_MAP.name if FLOPPY else 'tape_stage1 (from ' + CAS.name}): ${STAGE1[0]:04X}-${STAGE1[0] + STAGE1[1] - 1:04X} ({STAGE1[1]} B), "
          f"no loaded segment overlaps it (asserted)")
    else:
        P(f"  loader: {(LOADER_MAP if FLOPPY else CAS).name} not found, loader placement NOT checked")
    out = "\n".join(lines)
    print(out)
    if out_path:
        out_path.write_text(out + "\n")


if __name__ == "__main__":
    main()
