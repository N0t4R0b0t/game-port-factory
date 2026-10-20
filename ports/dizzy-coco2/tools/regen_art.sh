#!/usr/bin/env bash
# Regenerates every room's *_data.asm plus the shared font_data.asm,
# actor_data.asm and shared_sprites_data.asm from
# FRAMES.DAT/rooms.json/actors.json via roompack.
#
# VERBATIM CONVERSION -- no --shade, no --outline, no --close-actor-sprites,
# no --dither-floor. The Spectrum's own 1bpp art is emitted as-is.
#
# The ONE exception is --colour-flames-orange / --colour-water-blue, which
# drop ink from alternate screen columns in the animated flame/water tiles
# so composite NTSC resolves them to solid orange/blue (NOTES.md
# T0033-note). Those tiles are solid-filled blobs, so the halved horizontal
# detail costs nothing visible. Do NOT extend this to linework or sprites:
# it turns 1px detail into dotted detail, it does not colour it.
#
# The same applies to --colour-actor-orange/--colour-actor-blue, used for
# the solid-filled pickups: apple (17) and loaf (20) orange, jug of water
# (19) blue. Those three are >55% solid fill, so they survive the halved
# horizontal detail and gain a colour that says what they are. The rock
# (139) and rat (104) are deliberately left white. If you add a frame here,
# check its solid-fill share first -- anything under roughly half solid
# comes out as dotted mush.
#
# Every one of those transforms was invented to compensate for T0028 (the
# port was displaying CG6 at half horizontal resolution, which destroyed the
# original art's dither into colour mush). With the video mode fixed, the
# untouched Spectrum art reads correctly -- it is, after all, the same
# 256x192 1bpp bitmap the Spectrum itself draws. Verified on the troll
# (frame 96), the sprite that motivated the workarounds: verbatim it is a
# clearly readable creature, better than any processed version.
#
# WARNING when judging sprites: dithered art looks like meaningless noise
# when magnified and resolves into shading at native size. Judge it at 1:1
# in a real display capture (harness/capture_display.sh), never from a
# zoomed sprite dump. Calling the troll "illegible" from a 6x blowup is
# exactly how the workarounds got adopted in the first place.
#
# --shared-sprites target/shared_sprites_data.asm (T0035 follow-up): plain
# room-placement sprites are byte-identical no matter which room uses them,
# so a frame is emitted ONCE (global label, no room prefix) the first time
# any room needs it; later rooms just reference that label. This build is
# within a few hundred bytes of its hard memory ceiling (NOTES.md T0035),
# and duplicating 10+ shared wall/door tiles across three rooms was real,
# unnecessary cost. Rooms MUST run in the same order every time (they do,
# below) so the shared file's contents stay deterministic -- the file is
# deleted and rebuilt from scratch on every run, never appended to stalely.
#
# ROOM 52 (T0041/all-RAM investigation): re-enabled. The old $512-byte
# shortfall (T0033/T0035 memory audit -- see NOTES.md's "the real memory
# ceiling" entry for the full history) was a hard ceiling on the two 2KB
# gaps ($5800-$5FFF/$7800-$7FFF) alone; it's now moot because room 52's
# data lives at $8000+ instead, via the SAM's all-RAM mode (room36.asm's
# `start:` engages it and relocates this data up from a $0500 staging
# copy -- see its own comment for why staging is needed at all: BASIC's
# CLOADM loader can't write $8000+ directly). Deliberately NOT run
# through --shared-sprites here -- with ~32KB free up there, the cross-
# room dedup the two old 2KB gaps needed to survive buys nothing and
# just adds an ordering dependency on shared_sprites_data.asm.
#
# COINS (T0057): actors.json now also carries the original's
# `cointable` (30 static x,y,room triples), and roompack emits the ones
# belonging to --actor-rooms as `coin_init` plus the coin sprite itself,
# frame 0. That sprite is deliberately NOT registered in actor_spr_tab:
# that table is a linear scan terminated by a zero frame byte, so a
# frame-0 entry would truncate it -- draw_coins references aspr_0_w
# directly instead.
#
# Its pickupable "railingmess" railing section (extracted/actors.json
# room 52 slot 71, frame 192 at x=216,y=88) IS now in --actor-rooms
# below: it's a removable piece of the right-hand balustrade, and
# leaving it out left a visible gap in that railing -- real playtest,
# T0048. Its "proxpicture" trigger is handled directly in try_pickup
# (T0040), not through the actor table.
#
# ALWAYS verify headroom after any regen: assemble, then run
# `tools/memaudit.py`. It reads the built DECB image's BLOCK LIST --
# what actually lands where -- and that is the check that matters.
#
# A symbol scan is NOT enough and has now let three separate bugs
# through, because it sees the last LABEL in a file, not the last BYTE:
# T0052's save-under buffers overran the $7800 gap into room 52's
# sprites; room2_data.asm sat 225 bytes inside framebuffer B for
# several sessions; and T0058's four extra crocodile sprites pushed
# shared_sprites_data.asm's tail into `nibswap` at $7E00, which is
# filled at boot, so `blit` read a garbage sprite header and the
# machine reset itself a second after boot. Every one of those
# assembled and loaded without complaint.
#
# This is the SOURCE OF TRUTH for roompack's per-room flags -- twice now
# (room 36 first, then rooms 2/35) a session had to reverse-engineer the
# exact invocation from the committed .asm output because nothing recorded
# it. Don't let that happen a third time: when a room's flags change
# (new despeckle/mirror frame, a new room added, outline toggled off for
# one room only, ...), edit THIS file, not just the regenerated output.
#
# Usage: tools/regen_art.sh   (run from the port root, ports/dizzy-coco2/)
set -euo pipefail
cd "$(dirname "$0")/.."

ROOMPACK=./tools/roompack/target/release/roompack

# T0220: the ONE processing flag this script now applies, and it is per-frame,
# not global. These are the 49 frames used ONLY by DECORATIVE (non-solid)
# placements, reduced to drawn structure: every pixel not in a run of >=3 is
# dropped. The Spectrum artists filled these with 50% checkerboard to suggest a
# mid-tone their colour attribute tinted; on 1bpp that fill is a checkerboard
# that swamps the linework and speckles under NTSC artifact colour. Playtest:
# "the pictures on the wall are illegible" (room 52's picture is frame 160).
# Measured: drops 31% of their ink as fill, saves ~488 packed bytes.
#
# SAFETY: every id here is decorative-only, so nothing collidable changes.
# derive_room_cmask rasterises the collision mask FROM solid placements' ink, so
# adding a solid frame to this list could put holes in floors. Verify with
#   python3 -c "...set(dec)-set(sol)..."  (see NOTES.md "Where else
# --structure-run applies") before touching this list.
#
# NOT the troll (96) or its animation (97/98/99): this script's header records
# that verbatim beat every processed version on the troll, which is why global
# processing was reverted after T0028. Actor frames are T0220b, judged per frame.
# T0220 REVERTED BY PLAYTEST 2026-09-27: "we went too far, most art is now not
# recognizable". --structure-run 3 over all 49 decorative frames strips the stipple
# that gives these sprites their SHAPE, not just a flat mid-tone fill -- what is
# left reads as fragments. The +920 packed bytes were real and so was room 52's
# picture improving, but the trade is not acceptable across the whole set.
# Empty list = verbatim art, the known-good state. The --structure-frames
# machinery in roompack stays: it is inert with an empty list and is the right
# tool for a NARROW list, which is what T0220c has to establish, one frame at a
# time against a real screen.
# Both art filters are driven from the ENVIRONMENT so experiments need no edit
# here, and both default to EMPTY = verbatim art, the known-good state.
#
#   DESPECKLE_FRAMES=decor tools/regen_art.sh     # gentle: isolated pixels only
#   STRUCT_FRAMES=decor    tools/regen_art.sh     # aggressive: drop runs < 3
#   DESPECKLE_FRAMES=160,162 tools/regen_art.sh   # an explicit list
#
# `decor` expands to the 49 frames used ONLY by DECORATIVE (non-solid) placements.
# That restriction is the safety property: derive_room_cmask rasterises the
# collision mask FROM solid placements' ink, so filtering a solid frame could put
# holes in floors. Verified with cmaskverify (27 PASS / 0 FAIL) for the whole list.
# NOT the troll (96) or its animation (97/98/99) -- see this script's header.
DECOR_FRAMES=91,107,108,115,156,160,162,163,164,165,166,167,168,169,170,171,173,175,176,178,179,180,181,183,184,185,186,187,188,193,194,195,200,201,203,204,205,206,211,213,215,216,221,222,223,229,230,231,232

_expand() { [ "$1" = decor ] && echo "$DECOR_FRAMES" || echo "$1"; }
STRUCT=""
[ -n "${STRUCT_FRAMES:-}" ]    && STRUCT="--structure-frames $(_expand "$STRUCT_FRAMES")"
[ -n "${DESPECKLE_FRAMES:-}" ] && STRUCT="$STRUCT --despeckle-frames $(_expand "$DESPECKLE_FRAMES")"
[ -n "$STRUCT" ] && echo "ART FILTER: $STRUCT"
FRAMES=research/D3-prior-art/original_source/FRAMES.DAT
ROOMS=extracted/rooms.json
SHARED=target/shared_sprites_data.asm
SHARED_OVERFLOW=target/shared_sprites_overflow_data.asm
# T0121: one copy of the flame/water tiles for every room (roompack --shared-anim)
SHARED_ANIM=target/shared_anim_data.asm
# T0167: global room_placements frame index table (index -> sprite header
# addr), built up across every room in this run exactly like $SHARED --
# see roompack's --frame-table doc comment. Lives in framebuffer A's
# staged block (included right after shared_sprites_data.asm in
# room36.asm), so it's resident but never costs low-memory headroom.
FRAME_TABLE=target/frame_table_data.asm

if [ ! -x "$ROOMPACK" ]; then
    cargo build --release --manifest-path tools/roompack/Cargo.toml
fi

rm -f "$SHARED" "$SHARED_OVERFLOW" "$SHARED_ANIM" "$FRAME_TABLE"

# --shared-sprites-budget/-overflow (T0075): once $SHARED's own raw text
# reaches this many bytes, NEW shared frames go to $SHARED_OVERFLOW instead
# -- roompack's existing two-block mechanism (it already tracks labels
# across BOTH files in one set, so a frame used by rooms on each side of
# the split still only gets emitted once, wherever it first appears).
# Exists for exactly this reason (its own doc comment: "two separate
# small unused RAM blocks... not one big one"), but nothing had asked
# for the second block until now.
#
# 51+54+68+55 together (the room36.asm r9800 staging block, framebuffer
# B's 6KB window) ran to 7489 bytes source-side against a 6144-byte
# window when self-contained -- a silent 1345-byte overflow present
# since T0074 added room 55 there, caught only when T0075's actor
# growth shifted the corrupted bytes onto a sprite header that hangs
# `blit` instead of merely drawing something wrong (NOTES.md T0075 has
# the full trace). Deduplicating ALL nine rooms below into one growing
# pool, then routing whatever doesn't fit in r8000's small remaining
# margin into $SHARED_OVERFLOW (included in the r9800 block instead --
# it has real headroom once 51/54/68/55's own dedup shrinks them, unlike
# r8000, which had almost none to spare even before this), closes the
# gap without hand-splitting which room's tiles go where.
SHARED_BUDGET=6200
$ROOMPACK $STRUCT --frames "$FRAMES" --rooms "$ROOMS" --shared-anim "$SHARED_ANIM" --room 2 --colour-flames-orange \
  --shared-sprites "$SHARED" --shared-sprites-budget $SHARED_BUDGET \
  --shared-sprites-overflow "$SHARED_OVERFLOW" --frame-table "$FRAME_TABLE" --output target/room2_data.asm

# Room 35: Smuggler's Hideout, room 36's west neighbor. No actors of its
# own (all interactive objects for this vertical slice live in room 36).
$ROOMPACK $STRUCT --frames "$FRAMES" --rooms "$ROOMS" --shared-anim "$SHARED_ANIM" --room 35 \
  --colour-flames-orange --colour-water-blue \
  --shared-sprites "$SHARED" --shared-sprites-budget $SHARED_BUDGET \
  --shared-sprites-overflow "$SHARED_OVERFLOW" --frame-table "$FRAME_TABLE" --output target/room35_data.asm

# Room 52: THE ENTRANCE HALL, room 36's north neighbor (T0035). Its own
# `org $0100`/PHASE staging block lives directly in room36.asm, right
# before `end start`.
$ROOMPACK $STRUCT --frames "$FRAMES" --rooms "$ROOMS" --shared-anim "$SHARED_ANIM" --room 52 --colour-flames-orange \
  --shared-sprites "$SHARED" --shared-sprites-budget $SHARED_BUDGET \
  --shared-sprites-overflow "$SHARED_OVERFLOW" --frame-table "$FRAME_TABLE" --output target/room52_data.asm

# Room 53: SNAP HAPPY GATOR, room 52's east neighbor (T0036).
# --colour-water-blue: this room has real water tiles, room 52 didn't.
$ROOMPACK $STRUCT --frames "$FRAMES" --rooms "$ROOMS" --shared-anim "$SHARED_ANIM" --room 53 --colour-flames-orange \
  --colour-water-blue --shared-sprites "$SHARED" --shared-sprites-budget $SHARED_BUDGET \
  --shared-sprites-overflow "$SHARED_OVERFLOW" --frame-table "$FRAME_TABLE" --output target/room53_data.asm

# Room 69: THE EAST WING (above 53) -- lives in the r8000 staging block
# alongside 52/53/room2.
$ROOMPACK $STRUCT --frames "$FRAMES" --rooms "$ROOMS" --shared-anim "$SHARED_ANIM" --room 69 --colour-flames-orange \
  --colour-water-blue --shared-sprites "$SHARED" --shared-sprites-budget $SHARED_BUDGET \
  --shared-sprites-overflow "$SHARED_OVERFLOW" --frame-table "$FRAME_TABLE" --output target/room69_data.asm

# Rooms 51, 54, 68 (T0067) + 55 (T0074): the r9800 staging block --
# 51 MOAT AND PORTCULLIS (west of 52), 54 THE WIDE-EYED DRAGON (east of
# 53), 68 THE BANQUET HALL (above 52), 55 THE BOTTOMLESS WELL (east of
# 54, T0038's scoped frontier). See games/dizzy/recipe/MAP.md for why
# these and no others.
for room in 51 54 68 76; do
    $ROOMPACK $STRUCT --frames "$FRAMES" --rooms "$ROOMS" --shared-anim "$SHARED_ANIM" --room $room \
      --colour-flames-orange --colour-water-blue \
      --shared-sprites "$SHARED" --shared-sprites-budget $SHARED_BUDGET \
      --shared-sprites-overflow "$SHARED_OVERFLOW" --frame-table "$FRAME_TABLE" --output target/room${room}_data.asm
done
# Room 67 (T0084): THE WEST WING, ABOVE room 51 -- building it is what
# stops room 51's staircase stranding Dizzy above the play window, since
# the up-transition then actually succeeds instead of being refused
# (NOTES.md T0081/T0082).
#
# Was deliberately reuse-only (not fully self-contained, but not allowed to
# GROW the shared pool either) for the same r9800-headroom reason as
# below -- see T0144's note on the reuse-only loop further down, where it
# now runs through the full shared pool like every other room.

# Rooms 84 (THE CASTLE STAIRCASE, above 68) and 85 (THE EAST TOWER,
# above 69), T0094. Building them is what stops rooms 68 and 69 doing
# what room 51 used to do -- stranding Dizzy above the play window when
# an up-transition is refused (NOTES.md T0081).
#
# Was reuse-only, for the same reason room 67 was -- see T0144's note on
# the reuse-only loop further down, where they now run through the full
# shared pool like every other room. Measured standalone before wiring
# them in as self-contained (NOTES.md T0083's method, never from .asm text
# size): 1309 and 1331 bytes raw, against the 2947 bytes of PACKED
# headroom T0085 opened up in r8000.

$ROOMPACK $STRUCT --frames "$FRAMES" --rooms "$ROOMS" --shared-anim "$SHARED_ANIM" --room 55 \
  --colour-flames-orange --colour-water-blue \
  --shared-sprites "$SHARED" --shared-sprites-budget $SHARED_BUDGET \
  --shared-sprites-overflow "$SHARED_OVERFLOW" --frame-table "$FRAME_TABLE" --output target/room55_data.asm

# Room 36: the dungeon -- the vertical slice's main room. Also emits the
# shared font (glyphs are ordinary frmtable frames) and the shared actor
# table (apple/jug/loaf/rock/rat/troll, plus room 52's removable railing
# section and room 53's gator/rock/whiskey, spread across rooms
# 35+36+52+53 via --actor-rooms -- T0048/T0049, both reported as
# "missing" in a real playtest because those rooms' actors were never
# wired). --mirror-frames is the rat (104), which needs a mirrored
# variant for its patrol direction, and the crocodile (123 closed, 124
# open), which the original turns to face Dizzy via bit 7 of its colour
# byte. --extra-actor-frames 124 emits the croc's open mouth, which no
# actor SLOT names -- crocodilerou switches to it at runtime. T0071
# adds three more for the same reason: 110 (the dragon's mid-roar head,
# swapped in during the first third of a fire-breath cycle), 111 (one
# of its six neck segments -- SLOT_ONLY names the head's own frame,
# 109, never the neck), and 112 (the flame sprite itself).
# (--close-actor-sprites and --outline are deliberately NOT used here; see
# the header. The flags still exist in roompack for future targets whose
# display genuinely cannot carry the original dither.)
# --glyph-override 81 (T0077): 'Q' ('&' + 43 -- never printed by any
# message in this game, checked against every string in
# gap_messages.asm/actors.json) repurposed as a tiny hand-drawn egg-face
# icon for the status bar's lives count, replacing the plain "L" --
# same 8x8 slot, same font_table, same prtmessage draw path, zero new
# code or memory. See regen_art.sh's own header note above every custom
# --glyph-override: this is the SOURCE for that bitmap, edit here, not
# in the generated font_data.asm.
$ROOMPACK $STRUCT --frames "$FRAMES" --rooms "$ROOMS" --shared-anim "$SHARED_ANIM" --room 36 --colour-flames-orange \
  --shared-sprites "$SHARED" --shared-sprites-budget $SHARED_BUDGET \
  --shared-sprites-overflow "$SHARED_OVERFLOW" --frame-table "$FRAME_TABLE" \
  --glyph-override "81:0x3c,0x7e,0xff,0xe7,0xff,0xff,0x7e,0x3c" \
  --output target/room36_data.asm --font-output target/font_data.asm \
  --actors extracted/actors.json --actor-rooms 35,36,51,52,53,54,55,68,69,83,86,100,87,50,56,71,85,84,24,57,72,58,59,60 \
  --actor-output target/actor_data.asm --mirror-frames 104,123,124,102,103,127 \
  --extra-actor-frames 124,110,111,112,103,126 \
  --colour-actor-orange 17,20 --colour-actor-blue 19

# T0121 (superseded, see below): rooms that must not GROW the shared sprite
# pool (its overflow half lived in the nearly-full r9800 block -- why
# 67/84/85 were made fully self-contained in T0084/T0094) but should REUSE
# every tile it already holds. 70 is the EMPTY room between 86 and 54
# (T0120).
#
# T0144: switched from --shared-sprites-reuse-only to full pool feeding
# (--shared-sprites-budget, same as every other room above). Reuse-only
# meant a frame these rooms needed but no earlier room had already
# contributed got duplicated privately instead of joining the pool --
# spr_231 alone was private in 6 of these rooms (83/50/86/85/23/100), plus
# spr_200-203, ~794 bytes of avoidable duplication. That restriction dated
# to when the r9800 staging block (which holds $SHARED_OVERFLOW) had only
# 167 bytes free; T0142's sprite-mirroring cut ~870 bytes of image and took
# the title hole space from 130 to 868, so the headroom that motivated
# reuse-only is gone. Run after every earlier pool-feeding room so the pool
# is as complete as possible before these draw from (and add to) it.
for room in 67 84 85 83 86 100 70 87 50 56 71 39 23 24 57 72 58 59 60; do   # T0122: 87; T0123: 50; T0124: 56 THE LIFT CONTROL HUT, 71 DOZY'S HUT; T0125: 39 GOING DOWN THE WELL, 23 A STRANGE NEW WORLD; T0159: 24 INSIDE THE CHURCH, 57 BASE OF TREE HOUSE; T0161: 72 DENZIL'S PAD -- unlocked by moving gameplay code above $8000 (NOTES.md "The port is 58 packed bytes short of room 25") -- neighbours of built rooms needing no new behaviour routine
    $ROOMPACK $STRUCT --frames "$FRAMES" --rooms "$ROOMS" --shared-anim "$SHARED_ANIM" --room $room \
      --colour-flames-orange --colour-water-blue \
      --shared-sprites "$SHARED" --shared-sprites-budget $SHARED_BUDGET \
      --shared-sprites-overflow "$SHARED_OVERFLOW" --frame-table "$FRAME_TABLE" \
      --output target/room${room}_data.asm
done

# T0162: room 22 THE MARKET SQUARE -- unlocked by moving update_rat/
# update_troll/the hazard trio/update_armorog/update_lifts/update_dagger
# above $8000 (NOTES.md "the port is 993 packed bytes ..."). Back to
# --shared-sprites-reuse-only (T0121's own flag, superseded above by
# T0144 when block A had headroom to spare): block A's packed spare is
# down to 78 bytes again, and feeding room 22's frames into the pool
# grew shared_sprites_data.asm (block A) by enough to overflow it --
# measured, not assumed (`staging block A overflows framebuffer A`).
# Reuse-only keeps room 22's own new frames private in room22_data.asm
# (block B, which has real spare), same reasoning as rooms 67/83/84/85/
# 86/100 originally. Run AFTER every pool-feeding room, per the flag's
# own doc, so the pool is as complete as possible before this draws
# from it.
$ROOMPACK $STRUCT --frames "$FRAMES" --rooms "$ROOMS" --shared-anim "$SHARED_ANIM" --room 22 \
  --colour-flames-orange --colour-water-blue \
  --shared-sprites "$SHARED" --shared-sprites-budget $SHARED_BUDGET \
  --shared-sprites-overflow "$SHARED_OVERFLOW" --frame-table "$FRAME_TABLE" --shared-sprites-reuse-only \
  --output target/room22_data.asm

# T0230/T0233-fix: rooms 74/75 (THE GIANT BEANSTALK / COMPLEX CLOUD
# ROUTE) and the rest of the vertical slice's walkable rooms, tape-only.
#
# T0232: --shared-sprites-reuse-only -- dedup against the pool the 31
# -run rooms already built WITHOUT growing it. Growing $SHARED/
# $SHARED_OVERFLOW would change block A/B's RAW bytes, shared by BOTH
# the -run and tape builds (NOTES.md T0231) -- the -run build's
# room36.bin must stay byte-identical. Verified below by a byte-for-
# byte cmp of $SHARED/$SHARED_OVERFLOW against the pre-change files.
#
# T0233-fix: **every** room_placements entry (not just actors) is a
# 1-byte index into `frame_table` (tools/roompack/src/main.rs ~1388's
# own comment: "T0167: index into the global frame table... resolved
# back to a real pointer at room-load time only [derive_room_cmask,
# rd_sortplaces]") -- NOT just for actor draw dispatch. Rooms 74/75
# first shipped in T0230, and the 16 more rooms this round, were BOTH
# generated WITHOUT --frame-table on the theory that only actors needed
# it -- wrong: every one of these rooms' indices were assigned by a
# FRESH, ISOLATED roompack invocation starting at 0, with NO relation
# to the real, shared `frame_table` the 6809 code actually resolves
# them against at runtime. Symptom, found chasing cmaskverify's "too
# uniform to be per-room deviation" FAILs (a top-tier diagnosis, not
# found by trial and error): every tape room's DERIVED mask was reading
# essentially RANDOM sprites at essentially random sizes -- indices
# that happened to land in-bounds of the REAL frame_table, but pointing
# at whatever sprite the -run build's own rooms put there.
#
# Fix: a SEPARATE, tape-only frame table ($FRAME_TABLE_TAPE) that
# starts as an exact copy of the -run build's own $FRAME_TABLE (so
# every index the -run build's rooms already assigned still resolves
# identically) and grows ONLY from these 18 rooms' own new sprites.
# `frame_table_data_tape.asm` is included instead of `frame_table_data.
# asm` only when TAPE_ROOMS=1 (target/room36.asm's own `if TAPE_ROOMS`
# switch, same pattern as staged_syms.asm et al) -- so this can ONLY
# grow the tape build's own independent block A/B pass (T0231), never
# the -run build's.
FRAME_TABLE_TAPE=target/frame_table_data_tape.asm
cp "$FRAME_TABLE" "$FRAME_TABLE_TAPE"

# T0235 PHASE 2: TAPE-ONLY duplicates of the 28 base rooms that live in
# the staged $8000+ blocks below (room2/room35/room36 excluded -- room2
# has no room_desc_table entry, room35/room36 live at $0100 outside the
# staged-block mechanism entirely; see NOTES.md T0235). Same coupling
# class as frame_table_data_tape.asm/actor_data_tape.asm above: a SECOND
# roompack invocation per room, output to roomNN_data_tape.asm, included
# ONLY when TAPE_ROOMS=1 (room36.asm's own `if TAPE_ROOMS`), so the -run
# build's roomNN_data.asm (and room36.bin) are completely untouched.
#
# --shared-sprites-reuse-only: every one of these rooms' own sprites is
# ALREADY in the shared pool from its first (this script's own, above)
# generation -- this second pass must never grow it (growing $SHARED/
# $SHARED_OVERFLOW a second time here would double-count budget against
# the SAME framebuffer windows the -run build's own pass already sized
# against). --frame-table "$FRAME_TABLE_TAPE": every index these rooms
# use already exists (copied from $FRAME_TABLE above), so this is a
# lookup, not a growth, for all 28 -- confirmed by frame_table_data_tape.
# asm's own byte count not changing across this loop (checked, not
# assumed: it only grows again in the NEW-tape-room loop below, and did
# not for this one during testing).
#
# --pack-room-data: see roompack's own doc comment. A room whose packed
# size does not beat its raw size (matching room 77's own case, T0235
# PHASE 1) falls back to raw automatically -- no per-room exclusion list
# needed here.
for room in 52 53 69 67 84 85 83 86 70 50 71 57 72 58 59 60 \
            51 54 68 55 100 87 56 24 22 76 39 23; do
    $ROOMPACK $STRUCT --frames "$FRAMES" --rooms "$ROOMS" --shared-anim "$SHARED_ANIM" --room $room \
      --colour-flames-orange --colour-water-blue \
      --shared-sprites "$SHARED" --shared-sprites-budget $SHARED_BUDGET \
      --shared-sprites-overflow "$SHARED_OVERFLOW" --shared-sprites-reuse-only \
      --frame-table "$FRAME_TABLE_TAPE" \
      --pack-room-data \
      --output target/room${room}_data_tape.asm
done

# T0235: --pack-room-data -- each of these 19 rooms' own placements/
# flames/water ship as ONE LZ-packed blob instead of three raw tables
# (tools/roompack/src/lz.rs, mirrored by lz_unpack, target/boot_code.
# asm); room36.asm's load_room (gated `if TAPE_ROOMS`) unpacks the
# current room into the shared ROOM_UNPACK_BUF before deriving its
# mask. TAPE_ROOMS-only: the -run build's load_room has no matching
# unpack branch, so this flag must never reach the -run build's own
# regen_art.sh calls above. Measured offline (all 50 rooms): 9281 raw
# -> 8149 packed; see NOTES.md T0235 for the real, on-target net.
for room in 74 75 63 91 92 45 48 49 94 89 41 73 88 93 40 46 31 47 77; do
    $ROOMPACK $STRUCT --frames "$FRAMES" --rooms "$ROOMS" --shared-anim "$SHARED_ANIM" --room $room \
      --colour-flames-orange --colour-water-blue \
      --shared-sprites "$SHARED" --shared-sprites-budget $SHARED_BUDGET \
      --shared-sprites-overflow "$SHARED_OVERFLOW" --shared-sprites-reuse-only \
      --frame-table "$FRAME_TABLE_TAPE" \
      --pack-room-data \
      --output target/room${room}_data.asm
done
# T0233: NONE of these 18 rooms are wired into the shared ACTOR table
# (--actors/--actor-rooms): extracted/actors.json lists real actor
# entries for several of them (40 hawk/dragon/pickupable, 41 crowbar/
# miner, 45 pickupable/dozyfloat, 48 log/pickupable, 49 hawk, 73
# daisy1/pickupable, 88 lift/pickupable, 89 pickupable, 93 pickupable,
# 94 dagger/crowbar/lift/daisy/switch1) -- wiring any of them into
# --actor-rooms would grow actor_data.asm, RESIDENT low memory shared
# by BOTH builds, breaking the -run build's byte-identity to HEAD (the
# same coupling class shared_sprites_data.asm/frame_table_data.asm
# have, fixed above for the LATTER but deliberately NOT attempted for
# the actor table this round -- a design decision, not made yet). Left
# OUT of --actor-rooms entirely: roompack then renders every one of
# these rooms' "things" (extracted/rooms.json) as ORDINARY STATIC
# SCENERY -- visible, in the right place (now that --frame-table is
# wired correctly), but inert (no lift motion, no dagger throw, no
# pickup, no hawk/dragon animation). See NOTES.md T0233 for the full
# per-room/per-actor list of what's missing.
# T0233-fix: room 77 THE ACTIVE VOLCANO is now built (in the loop
# above, with --colour-water-blue restored). roompack's water-tile
# code used to panic unconditionally ("water tiles at differing
# y-phases need per-tile variants") whenever a room's water/lava tiles
# don't share one y%4 phase -- room 77's lava has TWO phases (4 tiles
# at y%4==0, 2 at y%4==3). Fixed in tools/roompack/src/main.rs: picks
# the phase covering the MOST tiles (mode) for the room's single shared
# water animation, matching the FLAMES code's own already-accepted
# phase=0 simplification just above it in the same file -- draw_water
# (room36.asm) draws every water tile from ONE shared bitmap set with
# ONE shared counter already ("a synchronized ripple instead of a
# staggered one", its own comment), so there is no per-tile dispatch to
# feed even if multiple phase variants were emitted. See NOTES.md
# T0233 for the room's own verification (floor landing + killedbyvolcano).

# T0234: a SECOND, independent actor table for the tape-only region
# (target/actor_data_tape.asm), the same coupling class as
# frame_table_data_tape.asm above -- growing the SHARED actor_data.asm
# would break the -run build's byte-identity to HEAD (T0233's own
# reasoning for leaving --actor-rooms out entirely). roompack's
# --actor-suffix/--actor-no-coins/--actor-exclude-routines/--actor-
# template let a second --actors call coexist with the first: ACTOR_
# STRIDE/COUNT/SPR_N and actor_init/actor_spr_tab get a _tape suffix,
# ROU_* ids are NOT re-emitted (the shared dense id space -- actor_
# data.asm's own copy, already assembled earlier in room36.asm, is
# authoritative and identical), and the coin table is skipped (coins
# are a separate, unrelated mechanic -- out of scope this round).
#
# T0239: room 48 added to this list -- key 4 (frame 13, keymess/
# proxkey4) was excluded by T0234 specifically because of the
# cdt_key frame-collision bug fixed this round (gameplay.asm's
# cdt_key now dispatches on WHICH slot Dizzy is standing in, not on
# frame alone) -- safe to include now. Room 48's only other actor is
# `log` (X-ALL.TXT logrou, T0236's own "not a small routine on its
# own" finding) -- not special-cased anywhere, renders as ordinary
# static scenery, same "genuinely inert" class as this file's other
# unbuilt-routine actors.
# T0238: lift is no longer excluded -- update_lifts/ul_bounds/
# build_solid_actors all gained a tape-table second pass this round
# (rooms 40/88/94, wired via the existing ROU_LIFT dispatch; room 94's
# own switch1 co-tenant wired too, update_switch1 in actors.asm). Room
# 40's own lift (key2, room24, unbuilt) rides along for free since room
# 40 was already in this --actor-rooms list for its pickupables -- kept,
# not excluded, so its ul_bounds case exists and it draws correctly
# (off forever, same class as room 56's key4 lift, not a regression).
# dagger/crowbar/daisy (room 94's OTHER actors, pulled in by the same
# room-granular --actor-rooms) are excluded here deliberately: none are
# this round's task, and none of ROU_DAGGER/ROU_CROWBAR/ROU_DAISY are
# special-cased in draw_actors, so excluding them costs nothing (no
# static-scenery regression the way lift would have caused if left out
# unbounded) -- see NOTES.md T0238.
#
# --actor-exclude-routines lift (HISTORICAL, superseded above): room 88 has a lift (frame 125) in the
# same room as its two safe pickupables (crowbarhere, and a Doug NPC
# mis-tagged pickupable -- see below). draw_actors' dispatch special-
# cases ROU_LIFT unconditionally (jsr draw_lift, which reads per-room
# bounds from ul_bounds/logic_low.asm) -- unlike an un-special-cased
# routine (dragon/log/hawk/... -- see below), a lift entry with no
# ul_bounds case for its room would still run that dispatch and likely
# misdraw. Lift MOVEMENT is also not wired this round (update_lifts'
# own room gate, ul_bounds' per-room table, and build_solid_actors'
# lift-specific solid-body computation would all need a second,
# table-aware pass too -- three more coupled subsystems beyond the
# pickupable dual-table pattern actors.asm gained this round). Left
# for a follow-up round; see NOTES.md T0234.
#
# Only rooms with at least one SAFE pickupable are listed (--actor-
# rooms is room-granular, so every pickupable-routine actor in a listed
# room comes along, not just the one motivating its inclusion -- each
# was checked against gameplay.asm's own frame-keyed logic before
# accepting that): 40 (goldenegghere1 fr10, rugmess fr12), 45
# (sleepingpotionhere fr15 -- FRAME_POTION already has cdt_potion ready
# and room 54 built; dozyhere fr32 -- a person mistagged pickupable,
# same class as the ALREADY-SHIPPED Dylan fr34 entry in actor_data.asm,
# not a new regression), 73 (windowmess fr204), 88 (crowbarhere fr4 --
# FRAME_CROWBAR already has cdt_crowbar ready and room 55 built;
# doughere fr36 -- a person, same class as dozyhere above), 89
# (doorknockermess fr21), 93 (goldenegghere fr10). room48's frame-13
# item (keymess/proxkey4) was checked and EXCLUDED: frame 13 collides
# with FRAME_KEY's cdt_key dispatch (gameplay.asm), which is keyed on
# frame alone and hardcodes room 56's key-1 box -- carrying key4 there
# would wrongly fire the key-1 reward. (The -run build already has this
# same frame-13 collision three times over among its own pickupables,
# so it is a known, accepted simplification in general -- but adding a
# FOURTH instance whose real identity is a different, unbuilt puzzle
# piece was judged not worth compounding this round.) See NOTES.md
# T0234 for the full per-room/per-actor check.
#
# --actor-template: the user reported non-resetting tape rooms after a
# game over as a real bug (this table's own "no separate ROM master"
# design, above, made every pickup PERMANENT for the rest of the tape
# session). Emits a second, pristine copy of the same 12 records under
# actor_init_tape_template -- reset_tape_actors (actors.asm, T0234)
# restores actor_init_tape FROM it on new_game, the same role
# actor_init already plays for the -run build's own actor_ram via
# actors_init. Costs another ~96 bytes (12 slots x 8), all ROM data --
# see NOTES.md T0234 for the measured before/after.
# T0223: room 22 added to --actor-rooms: shopkeeperhere (frame 105), its
# mirrored second half shopkeeperhere1 (routine `crowbar`, kept by roompack's
# KEEP_DESPITE_EXCLUDE despite --actor-exclude-routines crowbar) and beanhere
# (frame 2; start position from the orig_x/orig_y fields, ORIG_POS_SLOTS slot 10).
# All three start in room 255 (ORIG_ROOM_LABELS): shopkeeperrou / shoptalk
# (tape_bean_code.asm) move them into the world. They sort between the hawk
# and the golden egg (slot order): DZ_POTION/DZ_FLOAT in tape_code.asm and the
# TB_* equs in tape_bean_code.asm index them.
# T0228: --extra-actor-frames gained 29,30,31 (the three heart sizes of the heart demo) and 37 (the
# Dizzy-like figure of room 3, beside Daisy frame 35); roompack's KEEP_DESPITE_EXCLUDE keeps `daisyhere`
# (room 94) despite --actor-exclude-routines daisy, and ORIG_ROOM_LABELS starts `daisy1here` in room 255.
# --no-tab-frames: tape_daisy_code.asm names those four sprites by label, so they stay out of actor_spr_tab.
$ROOMPACK $STRUCT --frames "$FRAMES" --rooms "$ROOMS" --shared-anim "$SHARED_ANIM" --room 40 \
  --colour-flames-orange --colour-water-blue \
  --shared-sprites "$SHARED" --shared-sprites-budget $SHARED_BUDGET \
  --shared-sprites-overflow "$SHARED_OVERFLOW" --shared-sprites-reuse-only \
  --output target/actor_data_tape_scratch_data.asm \
  --actors extracted/actors.json --actor-rooms 22,40,45,73,88,89,93,94,48,41,49 --extra-actor-frames 98,99,29,30,31,37 --no-tab-frames 29,30,31,37 \
  --actor-output target/actor_data_tape.asm --actor-suffix _tape --actor-no-coins \
  --actor-exclude-routines crowbar,daisy --actor-reuse-sprites target/actor_data.asm \
  --actor-template

# T0236: a SECOND, tape-only coin table (coin_init_tape) -- --coins-only
# (no actor_init at all: the actors in these rooms, where they exist,
# are already in actor_data_tape.asm above; re-emitting them here under
# a throwaway suffix would be dead data). Rooms: the 12 whose cointable
# entry (X-ALL.TXT, 30 total) falls in a tape-ONLY room (63,31,73,41,77,
# 46,92,89,94,49,75,40) plus 3 whose room (22,67,76) IS one of the -run
# build's own 31 base rooms but whose coin was never carried into the
# RESIDENT coin_init (pre-existing gap, 15/30 there, out of scope for
# this table -- see NOTES.md T0236) -- carrying them here instead reaches
# 30/30 for the TAPE build specifically without growing the shared/
# resident table (T0234's own byte-identity reasoning for actor_data.asm
# applies the same way to coin_init). 15 entries total; --actor-template
# for the same "no ROM master, needs a pristine copy to reset from"
# reason as actor_init_tape_template above.
$ROOMPACK $STRUCT --frames "$FRAMES" --rooms "$ROOMS" --shared-anim "$SHARED_ANIM" --room 40 \
  --colour-flames-orange --colour-water-blue \
  --shared-sprites "$SHARED" --shared-sprites-budget $SHARED_BUDGET \
  --shared-sprites-overflow "$SHARED_OVERFLOW" --shared-sprites-reuse-only \
  --output target/coin_data_tape_scratch_data.asm \
  --actors extracted/actors.json --actor-rooms 63,31,73,41,77,46,92,89,94,49,75,40,22,67,76 \
  --actor-output target/coin_data_tape.asm --coin-suffix _tape --coins-only \
  --actor-template

echo "regenerated room2/room35/room36/room52/room53 art + shared font/actor/sprite data"

# T0085: the staged $8000 blocks are stored PACKED, and the packing is a
# separate two-pass build that reads the RAW bytes back out. Regenerating
# art without re-running this leaves target/staged_*_lz.asm and
# staged_syms.asm describing the PREVIOUS art -- and the build still
# assembles, still loads and quietly draws the old rooms.
# Run it here rather than printing a reminder: a reminder that is not
# followed produces a build that assembles, loads and silently draws the
# PREVIOUS art, which is the worst available failure mode. It is
# idempotent, so running it always costs only the two assembler passes.
# REGEN_ART_NO_STAGE=1 (tools/bootstrap.sh): stop here; the bootstrap runs its own, ordered stage_pack passes.
[ "${REGEN_ART_NO_STAGE:-0}" = 1 ] && exit 0
exec "$(dirname "$0")/stage_pack.sh"
