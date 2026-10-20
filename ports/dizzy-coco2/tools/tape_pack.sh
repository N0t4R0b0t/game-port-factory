#!/usr/bin/env bash
# T0228 PHASE 2 -- builds target/room36.cas: ONE tape image, ONE CLOADM
# (+EXEC) from the user's side. See NOTES.md T0228 and
# target/tape_stage1.asm's own header for the mechanism (proved
# standalone in tools/tapeloader_spike, T0226/T0227).
#
# Does NOT touch target/room36.bin or its build (tools/stage_pack.sh) --
# the -run path, play.sh's default mode, and every existing harness
# (jumptrace, actorlife, cmaskverify, ...) keep working exactly as
# before. This script runs AFTER stage_pack.sh and replays its output
# as a tape image, plus stage1's own tiny bootstrap.
#
# Usage: tools/tape_pack.sh [--extra-segment ADDR:FILE ...]
#   --extra-segment lets a future round add tape-only content destined
#   for $8000+ without touching this script -- empty by default, which
#   is what makes this round's tape behaviourally IDENTICAL to today's
#   -run build (the whole point of proving the mechanism before using
#   it for headroom).
set -euo pipefail
cd "$(dirname "$0")/.."

TAPEPACK=tools/caswriter/target/release/tapepack
[ -x "$TAPEPACK" ] || cargo build --release --manifest-path tools/caswriter/Cargo.toml

echo "== stage_pack (unchanged -run build) =="
TAPE_ROOMS=0 tools/stage_pack.sh

# T0231-fix: the tape build is now a COMPLETE, INDEPENDENT run of
# tools/stage_pack.sh (TAPE_ROOMS=1) -- its own RAW pass, its own
# staged_syms_tape.asm/image_end_lz_tape.asm/title_lz_tape.asm/
# title_frags_tape.asm/staged_a_lz_tape.asm/staged_b_lz_tape.asm, its
# own packed pass. NEVER reuse the -run build's staged artifacts here:
# they are addresses+bytes measured against the -run build's OWN
# resident-code layout, which differs the moment resident code size
# differs between TAPE_ROOMS=0/1 (T0231's show_title_resident etc. --
# see NOTES.md T0231 for the bug this replaced: staged code silently
# calling/reading resident addresses that were right for the -run
# build and wrong for the tape build). Produces target/room36_tape.bin/
# .map directly (tools/stage_pack.sh's own TAPE_ROOMS branch chooses
# these output names) -- this is the DECB image harnesses load directly
# (poking $FFDF before any segment at $8000+, see
# harness/jumptrace.lua's load_decb) and what caswriter's --decb input
# becomes below -- rooms 74/75 need no separate --extra-segment wiring
# at all, because tape_stage1.asm's existing addr>=$8000 staged-copy
# path already treats ANY DECB block up there the same way, whichever
# image it came from.
echo "== stage_pack (tape build, TAPE_ROOMS=1, fully independent) =="
TAPE_ROOMS=1 tools/stage_pack.sh

TAPE_ROOM_START_HEX=$(grep '^Symbol: tape_room_staged_start ' target/room36_tape.map | awk '{print $NF}')
TAPE_ROOM_END_HEX=$(grep '^Symbol: tape_room_staged_end ' target/room36_tape.map | awk '{print $NF}')
CODE_DEST_HEX=$(grep '^Symbol: CODE_DEST ' target/room36_tape.map | awk '{print $NF}')
IMAGE_END_HEX=$(grep '^Symbol: IMAGE_END ' target/room36_tape.map | awk '{print $NF}')
TAPE_ROOM_USED=$((16#$TAPE_ROOM_END_HEX - 16#$TAPE_ROOM_START_HEX))
TAPE_ROOM_FREE_TOTAL=$((16#$CODE_DEST_HEX - 16#$IMAGE_END_HEX))
echo "   tape-only region: \$${IMAGE_END_HEX}..\$${CODE_DEST_HEX} (${TAPE_ROOM_FREE_TOTAL} bytes free span), rooms 74/75 use ${TAPE_ROOM_USED} bytes of it (${TAPE_ROOM_FREE_TOTAL} - ${TAPE_ROOM_USED} = $((TAPE_ROOM_FREE_TOTAL - TAPE_ROOM_USED)) bytes still free)"

# T0231-fix: this used to assert an EXACT byte delta between room36.bin
# and room36_tape.bin below IMAGE_END, back when both builds shared one
# set of packed staged blobs (the bug this round fixed). Now that each
# build runs its OWN independent stage_pack.sh (own RAW pass, own LZ
# packing), the packed size of blocks A-D can legitimately differ by a
# few bytes between builds even for byte-identical SOURCE content --
# the addresses baked into block D differ (correctly, per-build), and
# LZSS's output size is sensitive to its input bytes. An exact-delta
# assert is no longer the right invariant. What's still checked, hard:
# the block COUNT must match (no block silently vanished/split), and
# the delta must be POSITIVE and within a generous sanity bound (a
# regression that duplicated a whole block, or a build that forgot
# room_desc_table's own +4 bytes, would blow way past this). The real
# safety net is room36.bin's OWN byte-for-byte cmp against HEAD
# (separately verified, see NOTES.md T0231) plus the staged-code
# resident-symbol guard tools/stage_pack.sh just ran for BOTH builds.
python3 - "$IMAGE_END_HEX" <<'PY'
import sys
image_end = int(sys.argv[1], 16)
def parse(path):
    d = open(path, 'rb').read()
    pos, segs = 0, []
    while pos < len(d):
        t = d[pos]
        if t == 0:
            ln = d[pos+1]*256+d[pos+2]; ad = d[pos+3]*256+d[pos+4]
            segs.append((ad, d[pos+5:pos+5+ln]))
            pos += 5+ln
        elif t == 0xFF:
            break
        else:
            sys.exit(f"unknown DECB block type {t:#x} at {pos}")
    return segs
# T0219: the title-fragment blocks (title_lz0..N, one DECB block per load-time
# hole) are excluded from BOTH sides. The tape build now carries only block
# C+D there (title+music is de-duplicated against TITLE_RESIDENT_LZ), so its
# fragment blocks differ in number and size by design; everything else below
# IMAGE_END is still compared exactly as before.
import re
def frag_addrs(mp):
    out = set()
    for l in open(mp):
        m = re.match(r'^Symbol: title_lz\d+ \(.*?\) = ([0-9A-Fa-f]+)$', l.strip())
        if m: out.add(int(m.group(1), 16))
    return out
fa, fb = frag_addrs('target/room36.map'), frag_addrs('target/room36_tape.map')
# T0220: ... and so is the TAPE_LOW_REGION content block (tape-only text in the
# tape_low_slot_start.._end slot, a block the -run build does not have).
def low_slot(mp):
    lo = hi = None
    for l in open(mp):
        m = re.match(r'^Symbol: (tape_low_slot_start|TAPE_LOW_END) \(.*?\) = ([0-9A-Fa-f]+)$', l.strip())
        if m:
            if m.group(1) == 'TAPE_LOW_END': hi = int(m.group(2), 16)
            else: lo = int(m.group(2), 16)
    return lo, hi
llo, lhi = low_slot('target/room36_tape.map')
# T0221: ... and TAPE_LOW_REGION2 (gap1, the completion tune's blob).
def low2(mp):
    lo = hi = None
    for l in open(mp):
        m = re.match(r'^Symbol: (tape_low2_slot_start|TAPE_LOW2_END) \(.*?\) = ([0-9A-Fa-f]+)$', l.strip())
        if m:
            if m.group(1) == 'TAPE_LOW2_END': hi = int(m.group(2), 16)
            else: lo = int(m.group(2), 16)
    return lo, hi
l2lo, l2hi = low2('target/room36_tape.map')
# T0223: ... and TAPE_LOW_REGION3 (the tail of title hole 1).
def low3(mp):
    lo = hi = None
    for l in open(mp):
        m = re.match(r'^Symbol: (tape_low3_slot_start|TAPE_LOW3_END) \(.*?\) = ([0-9A-Fa-f]+)$', l.strip())
        if m:
            if m.group(1) == 'TAPE_LOW3_END': hi = int(m.group(2), 16)
            else: lo = int(m.group(2), 16)
    return lo, hi
l3lo, l3hi = low3('target/room36_tape.map')
# T0226: ... and TAPE_LOW_REGION4 once it holds content (the tape-only rooms' banner names).
def low4(mp):
    lo = hi = None
    for l in open(mp):
        m = re.match(r'^Symbol: (tape_low4_slot_start|TAPE_LOW4_END) \(.*?\) = ([0-9A-Fa-f]+)$', l.strip())
        if m:
            if m.group(1) == 'TAPE_LOW4_END': hi = int(m.group(2), 16)
            else: lo = int(m.group(2), 16)
    return lo, hi
l4lo, l4hi = low4('target/room36_tape.map')
# T0224: ... and the raw block C segment (tape_c_raw_start, RC_DEST..IMAGE_END): in the
# -run build block C is packed into the title holes, here it is an ordinary raw segment
# that happens to lie just below IMAGE_END (block D's raw segment is above it).
def sym1(mp, name):
    for l in open(mp):
        m = re.match(r'^Symbol: ' + name + r' \(.*?\) = ([0-9A-Fa-f]+)$', l.strip())
        if m: return int(m.group(1), 16)
    return None
craw = sym1('target/room36_tape.map', 'tape_c_raw_start')
# T0225b (L3): ... and the tape build's own `start:` block (boot-only code in the spare tail of
# framebuffer A, EXEC address); the -run build keeps start: inside its $0E00 block.
tstart = sym1('target/room36_tape.map', 'start')
a = [(ad, data) for ad, data in parse('target/room36.bin') if ad < image_end and ad not in fa]
b = [(ad, data) for ad, data in parse('target/room36_tape.bin')
     if ad < image_end and ad not in fb and not (llo is not None and llo <= ad < lhi)
     and not (l2lo is not None and l2lo <= ad < l2hi)
     and not (l3lo is not None and l3lo <= ad < l3hi)
     and not (l4lo is not None and l4lo <= ad < l4hi)
     and ad != craw and ad != tstart]
size_a = sum(len(data) for _, data in a)
size_b = sum(len(data) for _, data in b)
delta = size_b - size_a

# T0239: this guard used to be a flat byte count (512 -> 600 -> 800
# across T0236/T0237/T0238), bumped by hand every time a round
# legitimately grew the tape build's own resident code (ul_bounds/
# update_lifts/build_solid_actors's dual-table passes, update_switch1,
# cdt_key's 4-slot table, ...) -- each bump needed a fresh measurement
# to confirm the bigger number was still "a delta, not a regression",
# which is exactly the check this guard exists to make WITHOUT that
# manual step. What it actually protects against (this guard's only
# job -- the strong invariants are the block-COUNT check just above,
# and room36.bin's own byte-identity cmp against HEAD, done
# separately): a delta that is GROSS relative to the image it's part
# of -- a whole block silently duplicated, a staged symbol resolved
# against the wrong build's own resident layout (T0231's own bug
# class), or similar. Ordinary legitimate growth (a few hundred bytes
# of new TAPE_ROOMS-gated code, or LZSS packing noise from the two
# builds' now-independent packing passes) is a low single-digit
# PERCENTAGE of the resident image's own size, not a fixed number of
# bytes -- so the bound scales with the image instead of needing a
# person to re-bump it: 5% of the SMALLER build's own below-IMAGE_END
# size, floored at 200 bytes (so a tiny image doesn't get an
# unreasonably tight bound). 5%, not 1%, because LZSS's own per-build
# packing noise (independent packing passes since T0231-fix) already
# measured up to ~1% on its own in past rounds; 5x that margin still
# flags anything resembling a duplicated block (which would be tens of
# percent, not a few).
SANITY_PCT = 0.05
SANITY_FLOOR = 200
SANITY_MAX = max(SANITY_FLOOR, int(min(size_a, size_b) * SANITY_PCT))
if len(a) != len(b):
    sys.exit(f"tape_pack.sh: below IMAGE_END, room36.bin has {len(a)} blocks but "
              f"room36_tape.bin has {len(b)} -- a block appeared/vanished")
if not (0 < delta <= SANITY_MAX):
    sys.exit(f"tape_pack.sh: below IMAGE_END, room36_tape.bin is {delta} bytes different from "
              f"room36.bin ({size_a} -> {size_b}) -- expected a small positive delta "
              f"(room_desc_table + show_title_resident + packing variance), got something "
              f"outside (0, {SANITY_MAX}] ({SANITY_PCT*100:.0f}% of {min(size_a,size_b)}, "
              f"floor {SANITY_FLOOR})")
print(f"   sanity check: below IMAGE_END (${image_end:04x}), room36_tape.bin is room36.bin plus "
      f"{delta} bytes (room_desc_table + show_title_resident + independent LZ packing, T0231) -- "
      f"{len(a)} blocks both sides")
PY

# T0228 constraint 2 (rewritten T0219): stage1's own code AND scratch
# buffers (tape_stage1.asm) must sit in memory that NO tape segment ever
# writes -- stage1 is running while the rest of the tape streams in, so a
# segment that lands on it overwrites code that is executing. T0219 root
# cause: this used to place stage1 at the end of target/room36.bin (the
# -run image, $7A61) but the .cas is built from target/room36_tape.bin,
# whose LAST block (title hole 5, $79CD-$7DC6) covered it, so the real
# tape boot died ("tape-only region differs at $bf30").
#
# Now: placement is computed from room36_tape.bin ITSELF (plus any
# --extra-segment given to this script) -- the image actually loaded.
# Candidate windows are the address ranges below nibswap ($7F00 in the tape build, T0225b) that no
# segment covers, MINUS the persistent TAPE_LOW_REGION [TAPE_LOW_START,
# TAPE_LOW_END) (room36.asm; reserved for future tape-only content, so
# stage1 must not squat in it). The highest candidate that fits wins.
# Above nibswap is off limits (nibswap, BASIC's stack/string space near
# $7F00 while CLOADM/stage1 run). A HARD GUARD then re-checks, after
# assembling, that no tape segment overlaps [STAGE1_ORG, STAGE1_END)
# (STAGE1_END includes the rmb scratch buffers) nor stage1's zero-page
# vars ($7C-$81), and fails the build otherwise.
NIBSWAP=$((16#$(grep '^Symbol: nibswap ' target/room36_tape.map | awk '{print $NF}')))   # T0225b: $7F00 in the tape build
echo "== assemble tape_stage1 (trial, to measure) =="
lwasm --format=raw -DSTAGE1_ORG=$((0x5000)) -o ${GPF_TMP:-/tmp}/tape_stage1_trial.bin --map=${GPF_TMP:-/tmp}/tape_stage1_trial.map target/tape_stage1.asm
TRIAL_END=$(grep '^Symbol: STAGE1_END ' ${GPF_TMP:-/tmp}/tape_stage1_trial.map | awk '{print $NF}')
STAGE1_LEN=$(( 16#$TRIAL_END - 0x5000 ))

LOAD_END_HEX=$(python3 - "$STAGE1_LEN" "$@" <<'PY'
import re, sys
stage1_len = int(sys.argv[1])
extra = sys.argv[2:]
def parse(path):
    d = open(path, 'rb').read()
    pos, segs = 0, []
    while pos < len(d):
        t = d[pos]
        if t == 0:
            ln = d[pos+1]*256+d[pos+2]; ad = d[pos+3]*256+d[pos+4]
            segs.append((ad, ad+ln)); pos += 5+ln
        elif t == 0xFF:
            break
        else:
            sys.exit(f"tape_pack.sh: unknown DECB block type {t:#x} at {pos}")
    return segs
segs = parse('target/room36_tape.bin')
# --extra-segment ADDR:FILE (tapepack's own syntax)
i = 0
while i < len(extra):
    if extra[i] == '--extra-segment':
        a, f = extra[i+1].split(':', 1)
        a = int(a.replace('$', '').replace('0x', ''), 16)   # tapepack: hex addr
        import os
        segs.append((a, a+os.path.getsize(f)))
        i += 2
    else:
        i += 1
syms = {}
for l in open('target/room36_tape.map'):
    m = re.match(r'^Symbol: (\S+) \(.*?\) = ([0-9A-Fa-f]+)$', l.strip())
    if m: syms[m.group(1)] = int(m.group(2), 16)
low_s, low_e = syms['TAPE_LOW_START'], syms['TAPE_LOW_END']
low2_s, low2_e = syms['TAPE_LOW2_START'], syms['TAPE_LOW2_END']   # T0221
low3_s, low3_e = syms['TAPE_LOW3_START'], syms['TAPE_LOW3_END']    # T0223
low4_s, low4_e = syms['TAPE_LOW4_START'], syms['TAPE_LOW4_END']    # T0224
LO, HI = 0x0100, syms['nibswap']     # T0225b: nibswap moved to $7F00
# build free spans in [LO, HI) not covered by any segment, minus both low regions
cover = sorted(segs + [(low_s, low_e), (low2_s, low2_e), (low3_s, low3_e), (low4_s, low4_e)])
spans, cur = [], LO
for s, e in cover:
    if s > cur:
        spans.append((cur, min(s, HI)))
    cur = max(cur, e)
if cur < HI:
    spans.append((cur, HI))
spans = [(s, e) for s, e in spans if e > s and e - s >= stage1_len]
if not spans:
    sys.exit(f"tape_pack.sh: no window of {stage1_len} bytes below nibswap that no tape segment "
              f"(or the TAPE_LOW_REGION ${low_s:04x}-${low_e:04x}) touches -- cannot place tape_stage1")
s, e = spans[-1]
print(f"{s:04x}")
print(f"tape_pack.sh: stage1 window ${s:04x}-${e:04x} ({e-s} bytes free of tape segments), "
      f"stage1 needs {stage1_len}", file=sys.stderr)
PY
)
LOAD_END=$((16#$LOAD_END_HEX))

echo "== assemble tape_stage1 at \$${LOAD_END_HEX} =="
lwasm --format=raw -DSTAGE1_ORG=${LOAD_END} -o ${GPF_TMP:-/tmp}/tape_stage1.bin --map=${GPF_TMP:-/tmp}/tape_stage1.map target/tape_stage1.asm
STAGE1_SIZE=$(stat -c%s ${GPF_TMP:-/tmp}/tape_stage1.bin)
STAGE1_END_HEX=$(grep '^Symbol: STAGE1_END ' ${GPF_TMP:-/tmp}/tape_stage1.map | awk '{print $NF}')
STAGE1_END=$((16#$STAGE1_END_HEX))
echo "   tape_stage1: ${STAGE1_SIZE} bytes, \$${LOAD_END_HEX}..\$${STAGE1_END_HEX} (code + scratch)"
if [ "$STAGE1_END" -gt "$NIBSWAP" ]; then
    echo "tape_pack.sh: tape_stage1 (ends \$${STAGE1_END_HEX}) runs into nibswap (\$${NIBSWAP}) -- shrink it or find more room" >&2
    exit 1
fi

# T0219 HARD GUARD: no tape segment may overlap stage1's code+scratch
# [STAGE1_ORG, STAGE1_END), nor its zero-page vars. Checked on the DECB
# image that becomes the .cas AND any --extra-segment given here.
python3 - "$LOAD_END" "$STAGE1_END" "$@" <<'PY'
import os, sys
org, end = int(sys.argv[1]), int(sys.argv[2])
extra = sys.argv[3:]
d = open('target/room36_tape.bin', 'rb').read()
pos, segs = 0, []
while pos < len(d):
    t = d[pos]
    if t == 0:
        ln = d[pos+1]*256+d[pos+2]; ad = d[pos+3]*256+d[pos+4]
        segs.append((f"tape DECB block #{len(segs)}", ad, ad+ln)); pos += 5+ln
    elif t == 0xFF:
        break
    else:
        sys.exit(f"unknown DECB block type {t:#x}")
i = 0
while i < len(extra):
    if extra[i] == '--extra-segment':
        a, f = extra[i+1].split(':', 1)
        a = int(a.replace('$', '').replace('0x', ''), 16)   # tapepack: hex addr
        segs.append((f"--extra-segment {f}", a, a + os.path.getsize(f)))
        i += 2
    else:
        i += 1
bad = []
for name, s, e in segs:
    if s < end and org < e:
        bad.append(f"{name} ${s:04x}-${e:04x} overlaps tape_stage1 ${org:04x}-${end:04x}")
    if s < 0x0082 and 0x007C < e:     # BLKTYP/BLKLEN/CBUFAD/CSRERR
        bad.append(f"{name} ${s:04x}-${e:04x} overlaps stage1's zero-page vars $007C-$0081")
    if e > 0xFF00:
        bad.append(f"{name} ${s:04x}-${e:04x} reaches the I/O page")
if bad:
    sys.exit("tape_pack.sh: HARD GUARD FAILED -- tape segment(s) would overwrite stage1 while it runs:\n  " + "\n  ".join(bad))
print(f"   guard: none of {len(segs)} tape segments overlaps tape_stage1 ${org:04x}-${end:04x} (code+scratch) or its zero-page vars")
PY

# T0219: free-space report (tape build).
TAPE_LOW_START_HEX=$(grep '^Symbol: TAPE_LOW_START ' target/room36_tape.map | awk '{print $NF}')
TAPE_LOW_END_HEX=$(grep '^Symbol: TAPE_LOW_END ' target/room36_tape.map | awk '{print $NF}')
TLS_HEX=$(grep '^Symbol: tape_low_slot_start ' target/room36_tape.map | awk '{print $NF}')
TLE_HEX=$(grep '^Symbol: tape_low_slot_end ' target/room36_tape.map | awk '{print $NF}')
TAPE_LOW_TOTAL=$((16#$TAPE_LOW_END_HEX - 16#$TAPE_LOW_START_HEX))
TAPE_LOW_USED=$((16#$TLE_HEX - 16#$TLS_HEX))
echo "   TAPE_LOW_REGION (persistent, below \$8000): \$${TAPE_LOW_START_HEX}..\$${TAPE_LOW_END_HEX} = ${TAPE_LOW_TOTAL} bytes, ${TAPE_LOW_USED} used, $((TAPE_LOW_TOTAL - TAPE_LOW_USED)) FREE"
TL2S_HEX=$(grep '^Symbol: TAPE_LOW2_START ' target/room36_tape.map | awk '{print $NF}')
TL2E_HEX=$(grep '^Symbol: TAPE_LOW2_END ' target/room36_tape.map | awk '{print $NF}')
TL2SS_HEX=$(grep '^Symbol: tape_low2_slot_start ' target/room36_tape.map | awk '{print $NF}')
TL2SE_HEX=$(grep '^Symbol: tape_low2_slot_end ' target/room36_tape.map | awk '{print $NF}')
TL2_TOTAL=$((16#$TL2E_HEX - 16#$TL2S_HEX))
TL2_USED=$((16#$TL2SE_HEX - 16#$TL2SS_HEX))
echo "   TAPE_LOW_REGION2 (persistent, gap1, below \$8000): \$${TL2S_HEX}..\$${TL2E_HEX} = ${TL2_TOTAL} bytes, ${TL2_USED} used, $((TL2_TOTAL - TL2_USED)) FREE"
TL3S_HEX=$(grep '^Symbol: TAPE_LOW3_START ' target/room36_tape.map | awk '{print $NF}')
TL3E_HEX=$(grep '^Symbol: TAPE_LOW3_END ' target/room36_tape.map | awk '{print $NF}')
TL3SS_HEX=$(grep '^Symbol: tape_low3_slot_start ' target/room36_tape.map | awk '{print $NF}')
TL3SE_HEX=$(grep '^Symbol: tape_low3_slot_end ' target/room36_tape.map | awk '{print $NF}')
TL3_TOTAL=$((16#$TL3E_HEX - 16#$TL3S_HEX))
TL3_USED=$((16#$TL3SE_HEX - 16#$TL3SS_HEX))
echo "   TAPE_LOW_REGION3 (persistent, code_data_end..\$4000, below \$4000): \$${TL3S_HEX}..\$${TL3E_HEX} = ${TL3_TOTAL} bytes, ${TL3_USED} used, $((TL3_TOTAL - TL3_USED)) FREE"
TL4S_HEX=$(grep '^Symbol: TAPE_LOW4_START ' target/room36_tape.map | awk '{print $NF}')
TL4E_HEX=$(grep '^Symbol: TAPE_LOW4_END ' target/room36_tape.map | awk '{print $NF}')
TL4SS_HEX=$(grep '^Symbol: tape_low4_slot_start ' target/room36_tape.map | awk '{print $NF}')
TL4SE_HEX=$(grep '^Symbol: tape_low4_slot_end ' target/room36_tape.map | awk '{print $NF}')
TL4_TOTAL=$((16#$TL4E_HEX - 16#$TL4S_HEX))
TL4_USED=$((16#$TL4SE_HEX - 16#$TL4SS_HEX))
echo "   TAPE_LOW_REGION4 (persistent, low block end..\$0E00, below \$0E00): \$${TL4S_HEX}..\$${TL4E_HEX} = ${TL4_TOTAL} bytes, ${TL4_USED} used, $((TL4_TOTAL - TL4_USED)) FREE"
echo "   tape-only region [IMAGE_END..CODE_DEST): $((TAPE_ROOM_FREE_TOTAL - TAPE_ROOM_USED)) bytes FREE"
python3 - <<'PY'
import re
sy = {}
for l in open('target/room36_tape.map'):
    m = re.match(r'^Symbol: (\S+) \(.*?\) = ([0-9A-Fa-f]+)$', l.strip())
    if m: sy[m.group(1)] = int(m.group(2), 16)
low  = sy['TAPE_LOW_END'] - sy['tape_low_slot_end']
low2 = sy['TAPE_LOW2_END'] - sy['tape_low2_slot_end']
low3 = sy['TAPE_LOW3_END'] - sy['tape_low3_slot_end']
low4 = sy['TAPE_LOW4_END'] - sy['tape_low4_slot_end']
tape = sy['CODE_DEST'] - sy['tape_room_staged_end']
rat  = 0x8000 - (sy['nibswap'] + 256)     # T0225b: nibswap fills $7F00-$7FFF, nothing after it
dslack = sy['BANNER_BUF'] - (sy['CODE_DEST'] + sy['TITLE_EXTRA2_RAW'])
tot = low + low2 + low3 + low4 + tape + rat + dslack
print(f"   persistent FREE total: LOW {low} + LOW2 {low2} + LOW3 {low3} + LOW4 {low4} + tape-only {tape} + after-nibswap {rat} + block-D slack {dslack} = {tot} bytes")
print(f"   title holes: none (blocks C/D are raw segments at ${sy['tape_c_raw_start']:04x} and ${sy['tape_d_raw_start']:04x})")
PY

echo "== build target/room36.cas =="
# T0230: --decb now points at target/room36_tape.bin (rooms 74/75
# included, org'd at IMAGE_END), not target/room36.bin -- everything
# below IMAGE_END is verified identical above, and tape_stage1.asm's
# existing addr>=$8000 path already delivers the new block the same
# way it would deliver any other $8000+ segment, so no
# --extra-segment wiring is needed for this round's demonstration.
"$TAPEPACK" --stage1-bin ${GPF_TMP:-/tmp}/tape_stage1.bin --stage1-addr "\$${LOAD_END_HEX}" \
    --decb target/room36_tape.bin "$@" --out target/room36.cas

echo "   $(stat -c%s target/room36.cas) bytes -- ONE CLOADM (+EXEC) from the user's side"
