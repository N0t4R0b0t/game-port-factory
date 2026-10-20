#!/usr/bin/env python3
"""Print the load-time holes below $8000 as mktitle --hole arguments.

Run between packing the rooms and the final assembly (tools/stage_pack.sh).
The holes MOVE whenever room data changes, because the framebuffer spares
begin wherever the packed blocks end -- hardcoding them goes stale silently
and the title would be written over live data.

T0107 added low-data and code+data as holes too, once staging Dizzy's
animation frames to $8000+ freed real headroom there (41 -> 4228 bytes in
code+data). Checked, not assumed, that this is safe: `low_resume` and
code+data's own top address are IDENTICAL between the raw pass (STAGE_GEN)
and the packed pass (STAGE_LZ) -- confirmed via both maps' `low_resume`
symbol -- because staged room data lives entirely outside those regions
(org'd to $4000/$6000, never touching $0100-$4000). The one real
circularity is title_frags.asm's own size (a few bytes per fragment,
itself resident in low-data) -- bounded and self-checking: T0095's
assembler guard fails loudly if this script's holes turn out wrong.

Free bytes come from the ACTUAL DECB BLOCK BOUNDARY in the raw pass, the
same method memaudit.py uses -- not from the last symbol, which a data
file's tail can run past silently (that exact bug cost a session once,
see memaudit.py's own header).

$7E00-$8000 is NOT loadable -- nibswap table and rat save-under, built at
boot -- so gap2 ends at $7E00. tools/memaudit.py's REGIONS is the authority.
"""
import os
import sys

# T0231-fix: prefix argument (tools/stage_pack.sh's $TMP) so a TAPE_ROOMS=1
# run reads ITS OWN raw pass/packed blocks, never the -run build's.
PREFIX = sys.argv[1] if len(sys.argv) > 1 else "/tmp/stage"


def region_top(path, lo, hi):
    """Highest used address in [lo, hi) from the RAW pass's actual DECB
    blocks -- memaudit's method, not the last label."""
    d = open(path, "rb").read()
    pos, top = 0, lo
    while pos < len(d) and d[pos] == 0:
        ln = d[pos + 1] * 256 + d[pos + 2]
        ad = d[pos + 3] * 256 + d[pos + 4]
        if ad < hi and lo < ad + ln:
            top = max(top, min(ad + ln, hi))
        pos += 5 + ln
    return top


def blocklen(path, addr):
    d = open(path, "rb").read()
    pos = 0
    while pos < len(d) and d[pos] == 0:
        ln = d[pos + 1] * 256 + d[pos + 2]
        ad = d[pos + 3] * 256 + d[pos + 4]
        if ad == addr:
            return ln
        pos += 5 + ln
    return 0   # T0123: nothing loads there any more (e.g. the $7800 gap after actor_data moved)


lenA = os.path.getsize(f"{PREFIX}_a.lz")
lenB = os.path.getsize(f"{PREFIX}_b.lz")
RAW = f"{PREFIX}_raw.bin"
holes = [
    (region_top(RAW, 0x0100, 0x0E00), 0x0E00),  # low data spare
    (region_top(RAW, 0x0E00, 0x4000), 0x4000),  # code+data spare
    (0x4000 + lenA, 0x5800),                        # framebuffer A spare
    (0x5800 + blocklen(RAW, 0x5800), 0x6000),   # gap1
    (0x6000 + lenB, 0x7800),                        # framebuffer B spare
    (0x7800 + blocklen(RAW, 0x7800), 0x7E00),   # gap2
]
# T0219: `tape` (tape build only) drops gap1 (index 3) and gap2 (index 5)
# from the list. Neither is a title hole there any more: gap2
# [gap2_end, $7E00) is the persistent TAPE_LOW_REGION (room36.asm), and
# gap1 [$5800+blocklen, $6000) is where tools/tape_pack.sh puts
# tape_stage1 (a window no tape segment may touch). The -run build's
# output (no 2nd argument) is unchanged.
if len(sys.argv) > 2 and sys.argv[2] == "tape":
    holes = [h for i, h in enumerate(holes) if i not in (3, 5)]
print(" ".join(f"--hole 0x{a:04x}:{b - a}" for a, b in holes if b > a))
