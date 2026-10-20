#!/usr/bin/env bash
# T0085 -- build room36.bin with the two staged $8000 blocks PACKED.
#
# WHY: staging is hard-capped at 12288 bytes. The two framebuffers are
# the only windows BASIC's CLOADM can write that are also free at boot,
# and the raw $8000 image is 11756 of them, so no further room fits.
# Packed it is ~7600 and the cap stops being the blocker.
#
# TWO PASSES, and the first one is not optional:
#
#   pass 1  assemble RAW (STAGE_LZ=0). This is what produces the bytes
#           to pack AND the addresses of every label inside the image.
#   pack    each window separately -- see room36.asm's note on why not
#           as one stream.
#   pass 2  assemble with STAGE_LZ=1, which swaps the room includes for
#           the blobs plus staged_syms.asm.
#
# Pass 2 has no room data in it at all, so the labels the resident code
# references (r52_room_place_count and 683 others) come from pass 1's
# map as absolute equs. That is only sound because the blocks are PHASEd
# to absolute $8000 and so do not move when resident code changes size.
# Re-run this whole script after ANY change to a room -- never assemble
# with -DSTAGE_LZ=1 by hand, the blobs go stale silently.
set -euo pipefail
cd "$(dirname "$0")/.."
LZ=tools/roompack/target/release/lzpack
[ -x "$LZ" ] || cargo build --release --manifest-path tools/roompack/Cargo.toml

# T0231-fix: this script is now a COMPLETE, independent pipeline per
# value of TAPE_ROOMS -- run it once with TAPE_ROOMS=0 (default, the
# -run build) and once with TAPE_ROOMS=1 (the tape build), and it
# NEVER shares an intermediate artifact between the two runs. Before
# this fix, tools/tape_pack.sh ran ONE extra STAGE_LZ=1 pass reusing
# the -run build's staged_syms.asm/staged_a_lz.asm/staged_b_lz.asm/
# image_end_lz.asm/title_lz.asm/title_frags.asm -- all of which are
# addresses+bytes measured against a SPECIFIC resident-code layout (the
# RAW pass that produced them). The moment resident code size differs
# between the two builds (T0231's show_title_resident etc.), staged
# code in the tape build called/read resident addresses that were
# right for the -run build and wrong for its own -- a silent, deeply
# confusing runtime bug (NOTES.md T0231: hours lost to it before this
# fix). Rule, permanent: NEVER reuse one build's staged artifacts in
# another build. Every artifact this script writes below is suffixed
# by TAPE_ROOMS's value so the two runs cannot collide on disk either.
TAPE_ROOMS=${TAPE_ROOMS:-0}
# T0241: FLOPPY=1 is a THIRD complete, independent pipeline run (the RS-DOS disk build, on top of the
# tape content): "_floppy"-suffixed artifacts, target/room36_floppy.bin/.map, nothing shared with the
# -run or tape builds (room36.asm picks the *_floppy.asm names under `if FLOPPY`).
FLOPPY=${FLOPPY:-0}
if [ "$FLOPPY" = 1 ]; then
    TAPE_ROOMS=1
    SUF=_floppy
    OUT_BIN=target/room36_floppy.bin
    OUT_MAP=target/room36_floppy.map
elif [ "$TAPE_ROOMS" = 1 ]; then
    SUF=_tape
    OUT_BIN=target/room36_tape.bin
    OUT_MAP=target/room36_tape.map
else
    SUF=
    OUT_BIN=target/room36.bin
    OUT_MAP=target/room36.map
fi
TMP=${GPF_TMP:-/tmp}/stage${SUF}   # GPF_TMP: tools/bootstrap.sh gives each run a private scratch dir

# T0225: DTE text compression. Regenerates target/{gap_messages,gameplay,
# actors,ui_room_names,rat_troll_hazard_code}.asm (fcc -> fcb byte lists)
# and target/dte_table.asm from the hand-edited target/text_src/*.asm.
# Never edit the target/*.asm copies directly -- rerun this script.
DTE=tools/dte/target/release/dte
[ -x "$DTE" ] || cargo build --release --manifest-path tools/dte/Cargo.toml
"$DTE" --root . build

# T0225b: the raw pass gets START_ITEMn too -- the TAPE build gates seed_inventory on them (room36.asm
# SEED_INV), so a raw pass without them would lay out 85 bytes differently from the final pass.
# T0188: a bare START_ROOM=N build used the ASM's fixed fallback of
# x=128,y=80, which in room 68 is inside the FIREPLACE -- "dizzy spawns
# in the fireplace, dies right away". play.sh already asked
# tools/start_pos.py for a safe spot when given a room argument; this
# makes the plain `START_ROOM=N tools/stage_pack.sh` path do the same,
# so the two cannot disagree. Explicit START_X/START_Y still win.
if [ -n "${START_ROOM:-}" ] && [ "${START_ROOM}" != 36 ] \
   && [ -z "${START_X:-}" ] && [ -z "${START_Y:-}" ]; then
    if _sp=$(python3 tools/start_pos.py "$START_ROOM" 2>/dev/null) && [ -n "$_sp" ]; then
        export START_X=${_sp%% *} START_Y=${_sp##* }
        echo "   START_ROOM=$START_ROOM -> safe spawn $START_X,$START_Y (tools/start_pos.py)"
    fi
fi

# T0221: the completion tune's mixer blob (TAPE build only). tune3 -> 3-voice
# mixer stream (same tool, rate and --semitone as the title tune, one 1311-frame
# loop) -> target/win_mix3.asm (title_mix3.asm + win_resume) assembled RAW ->
# LZ packed into target/win_mix3_lz.asm (TAPE_LOW_REGION2, gap1) + the sizes/
# offsets room36.asm needs (target/win_mix3_syms.asm). Generated BEFORE pass 1:
# room36.asm includes both, and pass 1 needs the sizes for its guards.
WINSUF=""
[ "$FLOPPY" = 1 ] && WINSUF=_floppy
if [ "$TAPE_ROOMS" = 1 ]; then
    MIX3S=tools/aycapture/target/release/mix3stream
    [ -x "$MIX3S" ] || cargo build --release --manifest-path tools/aycapture/Cargo.toml
    mkdir -p "${TMP}_win"
    "$MIX3S" tools/aycapture/captures/tune3_win.csv 1311 8529 "${TMP}_win/mix3_stream.asm" --semitone
    lwasm --format=raw -I"${TMP}_win" --map="${TMP}_win/win.map" -o "${TMP}_win/win_mix3.bin" target/win_mix3.asm
    "$LZ" "${TMP}_win/win_mix3.bin" "${TMP}_win/win_mix3.lz" --asm win_mix3_lz target/win_mix3_lz${WINSUF}.asm
    WIN_RAW=$(stat -c%s "${TMP}_win/win_mix3.bin")
    WIN_LZ=$(stat -c%s "${TMP}_win/win_mix3.lz")
    WIN_RESUME=$(grep '^Symbol: win_resume ' "${TMP}_win/win.map" | awk '{print $NF}')
    {
        echo "; Generated by tools/stage_pack.sh (T0221) -- do not edit."
        echo "WIN_MIX3_RAW    equ $WIN_RAW"
        echo "WIN_MIX3_LZ_LEN equ $WIN_LZ"
        echo "WIN_MIX3_RESUME equ \$$WIN_RESUME"
    } > target/win_mix3_syms${WINSUF}.asm
    echo "   completion tune blob: $WIN_RAW raw -> $WIN_LZ packed, resume at \$$WIN_RESUME"
fi

# T0241: FLOPPY=1 bootstrap. These two generated files are read by the RAW pass before mktitle has
# produced the real ones (same "run it twice" convention as title_frags_tape.asm, NOTES.md T0224):
# the title stream's length does not depend on the layout, so the tape build's numbers seed them.
if [ "$FLOPPY" = 1 ]; then
    [ -f target/title_frags_floppy.asm ] || cp target/title_frags_tape.asm target/title_frags_floppy.asm
    [ -f target/title_lz_floppy.asm ] || cp target/title_lz_tape.asm target/title_lz_floppy.asm
    [ -f target/title_resident_len_floppy.asm ] || grep '^TITLE_RESIDENT_LEN' target/title_resident_lz.asm > target/title_resident_len_floppy.asm
fi

echo "== pass 1: raw (TAPE_ROOMS=$TAPE_ROOMS FLOPPY=$FLOPPY) =="
lwasm --decb -DTITLE_MIX3=${TITLE_MIX3:-1} -DDEBUG_XY=${DEBUG_XY:-0} -DNO_CMASK=${NO_CMASK:-0} -DFB_CMASK=${FB_CMASK:-0} -DSINGLE_BUFFER=${SINGLE_BUFFER:-0} -DHCLIP=${HCLIP:-1} -DINF_LIVES=${INF_LIVES:-0} -DSTAGE_GEN=1 -DTAPE_ROOMS=$TAPE_ROOMS -DFLOPPY=$FLOPPY \
      ${START_ITEM1:+-DSTART_ITEM1=$START_ITEM1} ${START_ITEM2:+-DSTART_ITEM2=$START_ITEM2} ${START_ITEM3:+-DSTART_ITEM3=$START_ITEM3} \
      -o "${TMP}_raw.bin" --map="${TMP}_raw.map" target/room36.asm

python3 - "$TMP" "$SUF" <<'PY'
import re, subprocess, sys
TMP, SUF = sys.argv[1], sys.argv[2]
d = open(f'{TMP}_raw.bin','rb').read()
pos, blocks = 0, []
while pos < len(d) and d[pos] == 0:
    ln = d[pos+1]*256 + d[pos+2]; ad = d[pos+3]*256 + d[pos+4]
    blocks.append((ad, d[pos+5:pos+5+ln])); pos += 5 + ln

# The RAW pass deliberately overflows: once packing exists, the raw
# image is allowed to exceed the 12288-byte window cap (that is the
# whole point), so raw block A can run past $6000 and overlap block B's
# address space. That is harmless HERE only because each window is taken
# as a whole DECB block by its load address, never by address range --
# but it is harmless by construction, not by luck, so check it. The map
# is the authority on how long each block should be.
mapsyms = {}
for l in open(f'{TMP}_raw.map'):
    m = re.match(r'^Symbol: (\S+) \((.*?)\) = ([0-9A-Fa-f]+)$', l.strip())
    if m: mapsyms[m.group(1)] = int(m.group(3), 16)

def whole_block(addr, want_len, what):
    hit = [d for a, d in blocks if a == addr]
    if len(hit) != 1:
        sys.exit(f"{what}: expected exactly one DECB block at ${addr:04x}, got {len(hit)}")
    if len(hit[0]) != want_len:
        sys.exit(f"{what}: block at ${addr:04x} is {len(hit[0])} bytes, "
                 f"map says {want_len}")
    return hit[0]

lenA = mapsyms['r8000_staged_end'] - mapsyms['r8000_staged_start']
lenB = mapsyms['r9800_staged_end'] - mapsyms['r9800_staged_start']
A = whole_block(0x4000, lenA, "staging block A")
B = whole_block(0x6000, lenB, "staging block B")
open(f'{TMP}_a.bin','wb').write(A)
open(f'{TMP}_b.bin','wb').write(B)
# T0125: block C -- the image's tail, raw at $E000 in this pass only. It is
# not staged in a framebuffer: mktitle packs it into the title's load-time
# holes (--extra) and new_game unpacks it to RC_DEST.
lenC = mapsyms['rc_staged_end'] - mapsyms['rc_staged_start']
C = whole_block(0xE000, lenC, "staging block C")
open(f'{TMP}_c.bin','wb').write(C)
# T0148: block D -- RESIDENT CODE (update_dragon+dragon_flames). Unlike
# blocks A/B/C, assembled DIRECTLY at its real CODE_DEST address in this
# pass (no scratch org, no phase) -- see room36.asm's own comment for why:
# lwasm miscomputes relative branch offsets inside a phased block, and
# this is the first staged block with any branches in it. Extracted by
# code_staged_start's OWN address (whatever CODE_DEST resolved to), not a
# hardcoded scratch address. Not staged in a framebuffer and not appended
# to block C: mktitle packs it as its OWN stream (--extra2) into the
# title's load-time holes, and logic_low.asm's unpack_d unpacks it to
# CODE_DEST -- a fixed reservation below BANNER_BUF, not part of the
# [$8000, dest_end) room image, so it does not extend dest_end below.
lenD = mapsyms['code_staged_end'] - mapsyms['code_staged_start']
D = whole_block(mapsyms['code_staged_start'], lenD, "staging block D")
open(f'{TMP}_d.bin','wb').write(D)

# Every label inside the destination image, as absolute equs. The range
# is the image itself: $8000 .. $8000+len(A)+len(B)-1.
dest_end = 0x8000 + len(A) + len(B) + len(C)

# T0107/T0088: ANY hand-written `equ` constant in room36.asm can land
# inside [$8000, dest_end) by pure coincidence of its VALUE, regardless
# of what it represents -- TITLE_LZ_BUF (a real address up there) and
# NOTE_E5 (128*256+20 = $8014, a packed note constant with no address
# meaning at all) hit this the same way. An address-range test cannot
# tell "staged room-data label" from "constant that happens to look like
# one"; a name-based one can, generically, for every equ this file will
# ever gain -- not just the ones bitten so far. Parsed straight from the
# source rather than hand-listed, so a THIRD occurrence of this bug
# class can't happen by someone forgetting to update a list.
own_names = set(re.findall(r'^(\w+)\s+equ\b', open('target/room36.asm').read(), re.M))

syms = {}
for l in open(f'{TMP}_raw.map'):
    m = re.match(r'^Symbol: (\S+) \((.*?)\) = ([0-9A-Fa-f]+)$', l.strip())
    if not m: continue
    a = int(m.group(3), 16)
    # title_lzN labels are PLAIN LABELS (not equ) in a separate included
    # file (title_lz.asm), so the name-parse above can't see them --
    # they land in range the same way, via their disposable STAGE_GEN
    # scratch org ($c000+), for the title-screen chunks specifically.
    # T0123: and the staged blocks' own bracket labels -- once a RAW block
    # passes 8KB its end label (org $6000 + length) lands inside the image's
    # address range and was exported as if it were room data.
    if m.group(1).endswith(('_staged_start', '_staged_end')):
        continue
    if m.group(1) in own_names or m.group(1).startswith('title_lz'):
        continue
    if 0x8000 <= a < dest_end:
        if m.group(1) in syms and syms[m.group(1)] != a:
            sys.exit(f"duplicate staged symbol {m.group(1)}")
        syms[m.group(1)] = a
out = ["; Generated by tools/stage_pack.sh from the RAW pass -- do not edit.",
       ";",
       "; Every label inside the packed $8000 image, as an absolute equ.",
       "; Sound only because the staged blocks are PHASEd to absolute",
       "; $8000 and so never move; see room36.asm's STAGE_LZ note.",
       f"R9800_DEST equ ${0x8000 + len(A):04x}",
       f"RC_DEST equ ${0x8000 + len(A) + len(B):04x}",
       # T0148: block D's entry point AND its own local variables (moved
       # in WITH the code -- see gameplay.asm/dragon_code.asm's own notes
       # for why they could not stay resident below $8000) all live at/
       # above CODE_DEST, OUTSIDE the [$8000, dest_end) image range (see
       # room36.asm), so the generic range-scan below never finds them --
       # exported explicitly, literal, the same reason R9800_DEST/RC_DEST
       # are: pass 2 never assembles target/dragon_code.asm at all, so it
       # cannot recompute any of this itself. draw_dragon/dragon_necky
       # (room36.asm, unmoved) read several of these by name.
       *[f"{n} equ ${mapsyms[n]:04x}" for n in (
           'update_dragon', 'dragon_flames', 'dgf_i', 'dgf_x', 'udr_n', 'udr_slot',
           'udr_head_y', 'dragon_swing', 'dragon_delay', 'dragon_asleep',
           'dragon_fire', 'dragon_headfrm', 'dragon_flame_n',
           'dragon_flame_x',
           # T0161: update_crocodile + update_portcullis, same block,
           # same reason -- see croc_portcullis_code.asm's own header.
           'update_crocodile', 'uc_n', 'uc_slot',
           'update_portcullis', 'up_n', 'up_gate_hi', 'up_switch_hi',
           'up_dc',
           # T0162: update_rat/update_troll/the hazard trio, and
           # update_armorog/update_lifts/update_dagger, same block, same
           # reason -- see rat_troll_hazard_code.asm and
           # armorog_lifts_dagger_code.asm's own headers. Only entry
           # points and locals gameplay_init/update_item_triggers/
           # ul_bounds/actors.asm read or write BY NAME from resident
           # (pass-2-assembled) code are listed -- everything else
           # inside these two files is internal to block D and needs no
           # export (pass 2 never assembles either file at all).
           'update_rat', 'rat_dir', 'rat_step', 'rat_target_active',
           'rat_target_x', 'rat_fled',
           'update_troll', 'troll_greeted', 'troll_cooldown',
           'update_flame_hazard', 'update_water_hazard',
           'update_fire_hazard',
           'update_armorog', 'arm_strip_hdr',
           'update_lifts', 'ul_top', 'ul_bot', 'ul_obstruct',
           'update_dagger', 'font_table', 'FONT_FIRST', 'FONT_LAST',
           'tune1_notes', 'tune2_notes', 'tune5_notes', 'fx1_notes',
           'fx6_notes', 'fx10_notes', 'fx11_notes', 'fx21_notes',
           'fx25_notes') if n in mapsyms]]
for k in sorted(syms, key=lambda k: (syms[k], k)):
    if k not in ('R9800_DEST', 'RC_DEST'):
        out.append(f"{k} equ ${syms[k]:04x}")
# T0123: EQUATES defined inside staged files. actor_data.asm now lives in the
# packed image, and pass 2 assembles only the blobs plus this file -- so its
# ACTOR_COUNT / ACTOR_STRIDE / ROU_* / COIN_* constants, whose VALUES are
# small numbers nowhere near the image's address range, were never exported
# and every user of them failed to assemble. Carried over by name, verbatim.
for f in ['target/actor_data.asm']:
    for m in re.finditer(r'^(\w+)\s+equ\s+([^;\n]+)', open(f).read(), re.M):
        if m.group(1) not in syms:
            out.append(f"{m.group(1)} equ {m.group(2).strip()}")
open(f'target/staged_syms{SUF}.asm','w').write("\n".join(out) + "\n")

# T0107: IMAGE_END for the STAGE_LZ branch, same reasoning as R9800_DEST
# above -- room36.asm's own r9800_staged_end means "packed blob end" in
# that branch, not "raw content end", so the real answer only exists
# here, computed from the RAW pass. Getting this wrong once put
# IMAGE_END $BC10 instead of $C898, INSIDE the staged image rather than
# after it (NOTES.md T0107).
open(f'target/image_end_lz{SUF}.asm','w').write(
    f"; Generated by tools/stage_pack.sh from the RAW pass -- do not edit.\n"
    f"IMAGE_END equ ${dest_end:04x}\n")

print(f"   raw image {len(A)}+{len(B)}+{len(C)} = {len(A)+len(B)+len(C)} bytes, "
      f"{len(syms)} staged symbols, R9800_DEST=${0x8000+len(A):04x}, "
      f"IMAGE_END=${dest_end:04x}; T0148 code block D={len(D)} bytes at "
      f"update_dragon=${mapsyms['update_dragon']:04x}")
PY

echo "== pack =="
$LZ "${TMP}_a.bin" "${TMP}_a.lz" --asm r8000_lz_data "target/staged_a_lz${SUF}.asm"
$LZ "${TMP}_b.bin" "${TMP}_b.lz" --asm r9800_lz_data "target/staged_b_lz${SUF}.asm"

# T0092: the title screen goes into the load-time HOLES left below $8000,
# and where those holes start depends on how well the rooms just packed.
# So compute them here, between packing and the final assembly, rather
# than hardcoding addresses that go stale the moment a room changes.
#
# Only holes whose position is independent of CODE size are usable: the
# framebuffer spares (set by the packed block lengths) and the gaps after
# the org'd resident blocks at $5800 and $7800. The low-data and code+data
# spares move when the title's own 6809 code grows, which would make the
# build circular. Note gap2 ends at $7E00, not $8000 -- $7E00-$8000 is the
# nibswap table and rat save-under, built at boot and not loadable.
echo "== title screen =="
# T0219: the tape build leaves gap1 (tape_stage1's window) and gap2 (the
# persistent TAPE_LOW_REGION) out of the hole list, and de-duplicates the
# title+music prefix (already resident, TITLE_RESIDENT_LZ) out of the holes.
if [ "$TAPE_ROOMS" = 1 ]; then
    HOLES=$(python3 tools/title_holes.py "$TMP" tape)
else
    HOLES=$(python3 tools/title_holes.py "$TMP")
fi
echo "   holes: $HOLES"
# The REAL title screen, not the tape loading screen (T0096).
python3 tools/title_image.py research/D3-prior-art/info/dizzy3_title.png "${TMP}_title_raw.bin"
# TITLE_MIX3 (default 1, T0113): the 3-voice title mixer (target/title_mix3.asm) is
# position-independent, so it is assembled here once, raw, and handed to
# mktitle to ride the same holes as the title image.
MUSIC_ARG=""
if [ "${TITLE_MIX3:-1}" = 1 ]; then
    lwasm --format=raw -Itools/aycapture/captures -o "${TMP}_title_mix3.bin" target/title_mix3.asm
    MUSIC_ARG="--music ${TMP}_title_mix3.bin"
fi
# T0231: --resident-out is only generated for the tape build (TAPE_ROOMS=1)
# -- the -run build never includes target/title_resident_lz.asm at all.
RESIDENT_ARG=""
if [ "$TAPE_ROOMS" = 1 ]; then
    # T0223: --tail-region-end 0x4000 -> title_frags_tape.asm gets TAPE_LOW3_*
    # (the unused tail of the hole that ends at $4000 = TAPE_LOW_REGION3).
    # T0224: --raw-extras 1 -- blocks C and D are NOT in the title stream/holes any
    # more; their raw bytes ship as ordinary tape segments (see below). No holes are
    # used, so there is no --tail-region-end either: TAPE_LOW3/LOW4 are declared in
    # room36.asm from code_data_end / low_region_end.
    RESIDENT_ARG="--resident-out target/title_resident_lz${WINSUF}.asm --dedup-resident 1 --raw-extras 1"
    # The raw bytes pass 2 includes at RC_DEST / CODE_DEST (room36.asm, TAPE_ROOMS+STAGE_LZ).
    cp "${TMP}_c.bin" target/staged_c_raw${SUF}.bin
    cp "${TMP}_d.bin" target/staged_d_raw${SUF}.bin
fi
tools/roompack/target/release/mktitle "${TMP}_title_raw.bin" \
    "target/title_lz${SUF}.asm" "target/title_frags${SUF}.asm" $HOLES $MUSIC_ARG \
    --extra "${TMP}_c.bin" --extra2 "${TMP}_d.bin" $RESIDENT_ARG
if [ "$FLOPPY" = 1 ]; then
    # the floppy build includes only the LENGTH of the title blob (the blob itself is the DIZZY.OVL overlay)
    grep '^TITLE_RESIDENT_LEN' target/title_resident_lz_floppy.asm > target/title_resident_len_floppy.asm.new
    if ! cmp -s target/title_resident_len_floppy.asm target/title_resident_len_floppy.asm.new; then
        echo "   NOTE: TITLE_RESIDENT_LEN changed -> rerun tools/floppy_pack.sh (the raw pass used the old value)"
    fi
    mv target/title_resident_len_floppy.asm.new target/title_resident_len_floppy.asm
fi

echo "== pass 2: packed (TAPE_ROOMS=$TAPE_ROOMS) =="
# START_ROOM=51 ./play.sh drops Dizzy into room 51 at boot, for testing.
lwasm --decb -DTITLE_MIX3=${TITLE_MIX3:-1} -DDEBUG_XY=${DEBUG_XY:-0} -DNO_CMASK=${NO_CMASK:-0} -DFB_CMASK=${FB_CMASK:-0} -DSINGLE_BUFFER=${SINGLE_BUFFER:-0} -DHCLIP=${HCLIP:-1} -DINF_LIVES=${INF_LIVES:-0} -DSTAGE_LZ=1 -DTAPE_ROOMS=$TAPE_ROOMS -DFLOPPY=$FLOPPY -DSTART_ROOM=${START_ROOM:-36} \
      ${START_X:+-DSTART_X=$START_X} ${START_Y:+-DSTART_Y=$START_Y} \
      ${START_ITEM1:+-DSTART_ITEM1=$START_ITEM1} \
      ${START_ITEM2:+-DSTART_ITEM2=$START_ITEM2} \
      ${START_ITEM3:+-DSTART_ITEM3=$START_ITEM3} \
      -o "$OUT_BIN" --map="$OUT_MAP" target/room36.asm
# memaudit.py only understands the ORDINARY boot-time load path (blocks
# below $8000, the relocate loop, load-time holes). The TAPE_ROOMS
# region ($IMAGE_END..CODE_DEST) is delivered by a DIFFERENT mechanism
# entirely -- target/tape_stage1.asm's own addr>=$8000 segment copier,
# not the ordinary relocate loop -- so memaudit flags it as an
# "OVERRUN" (T0230 never ran memaudit against room36_tape.bin for this
# reason). Scoped to the -run build only.
# STAGE_SETTLE=1 (tools/bootstrap.sh only): a settling run on a tree whose title_*.asm are still
# placeholders -- the layout is not final yet, so the audits below would judge a transient image.
if [ "$TAPE_ROOMS" != 1 ] && [ "${STAGE_SETTLE:-0}" != 1 ]; then
    tools/memaudit.py "$OUT_BIN" "target/title_lz${SUF}.asm"
fi

# T0231-fix GUARD: staged code (dragon_code.asm/croc_portcullis_code.asm/
# rat_troll_hazard_code.asm/armorog_lifts_dagger_code.asm/sound_data.asm)
# references a handful of RESIDENT (below-$8000) globals BY NAME --
# lives, killed, kill_dizzy_msg, actor_ram, cur_room, dizzy_x/y/floor,
# force_redraw, keyflags, play_breath, troll_bribed. Those files are
# assembled ONCE, in THIS SAME pass 1 (raw), and the absolute addresses
# those names resolve to get BAKED into the bytes that get LZ-packed
# into block D -- pass 2 never re-assembles them, it only unpacks the
# same bytes at CODE_DEST (T0148's own note: "it may not reference a
# low-memory label that pass 2 can move -- either keep the data in the
# block or export it"). If pass 1's resident-code layout ever disagreed
# with pass 2's OWN resident code (the T0148 landmine: "PASS 1 AND PASS
# 2 DO NOT AGREE ABOUT LOW-MEMORY ADDRESSES"), the staged block would
# silently call/read the WRONG address -- exactly T0231's bug, except
# THAT was two DIFFERENT builds' artifacts crossed, not pass1-vs-pass2
# of the SAME build. Cheap to also guard the same-build case: assert
# every name below resolves IDENTICALLY in pass 1's raw map and this
# pass's own final map.
if [ "${STAGE_SETTLE:-0}" = 1 ]; then echo "   (STAGE_SETTLE=1: audits skipped)"; exit 0; fi
python3 - "$TMP" "$OUT_MAP" <<'PY'
import re, sys
TMP, out_map = sys.argv[1], sys.argv[2]
def load(path):
    syms = {}
    for l in open(path):
        m = re.match(r'^Symbol: (\S+) \((.*?)\) = ([0-9A-Fa-f]+)$', l.strip())
        if m: syms[m.group(1)] = int(m.group(3), 16)
    return syms
raw = load(f'{TMP}_raw.map')
final = load(out_map)
NAMES = ['lives', 'killed', 'kill_dizzy_msg', 'actor_ram', 'cur_room',
         'dizzy_x', 'dizzy_y', 'dizzy_floor', 'force_redraw', 'keyflags',
         'play_breath', 'troll_bribed']
bad = []
for n in NAMES:
    if n in raw and n in final and raw[n] != final[n]:
        bad.append(f"{n}: raw pass ${raw[n]:04x} (baked into staged code) vs "
                    f"final ${final[n]:04x}")
if bad:
    sys.exit("tools/stage_pack.sh: staged code was assembled (pass 1) against "
              "a DIFFERENT resident-code layout than the final image (pass 2) "
              "actually has -- " + "; ".join(bad))
print(f"   staged-code resident-symbol guard: {len([n for n in NAMES if n in raw and n in final])} "
      f"names checked, pass 1 (raw) and this build's own final map agree")
PY
