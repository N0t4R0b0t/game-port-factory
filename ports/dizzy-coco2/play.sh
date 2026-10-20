#!/usr/bin/env bash
# Build and launch the CoCo2 port in XRoar for real interactive play.
#
# Usage:
#   ./play.sh                 build + run
#   ./play.sh --no-build      run the committed target/room36.bin as-is
#   ./play.sh --tape          build + boot target/room36.cas via a real
#                              CLOADM+EXEC instead of -run (T0228 PHASE 2:
#                              proves the ONE-CLOADM tape loader, not a
#                              second game -- same room36.bin underneath,
#                              see tools/tape_pack.sh)
#   ./play.sh --floppy        build + boot target/dizzy.dsk the way you would on a
#                              real CoCo: Disk BASIC 1.1, LOADM"DIZZY":EXEC (T0241:
#                              FLOPPY build = the tape content + the title and the
#                              heart demo read from DIZZY.OVL on demand; tools/
#                              floppy_pack.sh). The disk is attached WRITE-BACK, so
#                              the DIZZY.SAV slot in target/dizzy.dsk is really
#                              written (the quick-save, T0242). --no-build runs the
#                              existing disk. Keys on this build: S = quick save,
#                              L = quick load (one slot, DIZZY.SAV; T0242; see
#                              docs/PLAYTEST-GUIDE.md). On a real machine: put dizzy.dsk on a
#                              35-track disk (Gotek/HxC/DriveWire/real format) and
#                              type  LOADM"DIZZY":EXEC  -- needs 64K and RS-DOS.
#   ./play.sh --inf-lives     build with infinite lives (playtest aid: a
#                              death still shows its box and respawns you,
#                              but never costs a life). Combines with the
#                              others, e.g. ./play.sh --tape --inf-lives.
#                              A later plain ./play.sh rebuilds WITHOUT it.
#   ./play.sh -- <xroar args>  pass extra flags through to xroar
#
# Controls: arrow keys move/jump, DOWN picks up / drops / opens inventory,
# SPACE dismisses a message and selects in the inventory.
#
# Joystick (TAPE build only, T0240): the RIGHT joystick works alongside the
# keys. X axis walks (slower than the keys at partial tilt, full speed at full
# tilt, dead zone at the centre), the fire button jumps, and also dismisses a
# message / selects in the inventory. Under XRoar:
#     ./play.sh --tape -- -joy-right mjoy0     # the mouse (move it left/right, left button = fire)
#     ./play.sh --tape -- -joy-right kjoy0     # cursor keys + Alt_L as the stick (arrows = full tilt)
#     ./play.sh --tape -- -joy-right <name>    # a gamepad: see `xroar -joy help`, or `-joy NAME
#                                              #   -joy-axis 0=0,0 -joy-button 0=0,0` + `-joy-right NAME`
# (`xroar -joy help` lists the profiles.) Keep the stick CENTRED when the game
# starts: a stick that never rests in the dead zone (nothing plugged in) is ignored.
#
# Display note: PMODE4 on a composite CoCo genuinely produces red/blue
# edging on fine detail -- that is real hardware behaviour, not a bug (it is
# the same effect Zaxxon and Time Bandit exploited deliberately). If you
# want to see the underlying black-and-white picture instead, add:
#     ./play.sh -- -vo-monochrome
# Do NOT reach for display flags to fix a picture that looks structurally
# wrong (wrong size, wrong colours, mush) -- that was T0028, and it was our
# video-mode bug, not the renderer. Check harness/capture_display.sh first.
set -euo pipefail
cd "$(dirname "$0")"

BUILD=1
TAPE=0
FLOPPY=0
# Leading flags, any order.
while :; do
    case "${1:-}" in
        --no-build)  BUILD=0; shift ;;
        --tape)      TAPE=1; shift ;;
        --floppy)    FLOPPY=1; shift ;;
        --inf-lives) export INF_LIVES=1; shift ;;
        *) break ;;
    esac
done
if [ "${INF_LIVES:-0}" = "1" ] && [ "$BUILD" = "0" ]; then
    echo "play.sh: --inf-lives is a build-time flag -- drop --no-build" >&2
    exit 2
fi

# A leading NUMBER is a room to start in: `./play.sh 51` drops Dizzy into
# room 51 instead of making you walk there. It is a BUILD-TIME define, so
# it cannot be combined with --no-build.
if [ "${1:-}" -eq "${1:-}" ] 2>/dev/null; then
    export START_ROOM="$1"; shift
    if [ "$BUILD" = "0" ]; then
        echo "play.sh: a room number needs a rebuild -- drop --no-build" >&2
        exit 2
    fi
    # T0191: ask Python, don't grep. BUILT is a WRAPPED list literal, so
    # "^BUILT = .*\b68\b" never matched room 68 (or anything past the
    # first line) and every such room got the scary "expect an empty room
    # or a fall through the floor" warning while working perfectly.
    if ! python3 -c "import sys; sys.path.insert(0,'tools'); import roomview; sys.exit(0 if $START_ROOM in roomview.BUILT else 1)"; then
        echo "play.sh: WARNING room $START_ROOM is not in tools/roomview.py's BUILT list;" >&2
        echo "         expect an empty room or a fall through the floor." >&2
    fi
    # Pick the spawn from the room's own collision mask. A fixed point
    # is inside a wall in some room: x=128,y=80 sits in room 69's
    # geometry, where the step-climb walks Dizzy out of the top of the
    # room and you arrive in 85 instead of 69.
    read -r _sx _sy <<<"$(python3 tools/start_pos.py "$START_ROOM")"
    export START_X="$_sx" START_Y="$_sy"
    echo "starting in room $START_ROOM at ($_sx,$_sy)"
fi

# Items to start holding. Given a room and no explicit list, the items
# that room's PUZZLE needs are worked out from the original source and
# seeded automatically -- `./play.sh 53` starts you holding the rope.
# See tools/room_items.py for how that is derived (every pickupable's
# prox routine names the room its trigger box is in). Override with an
# explicit list, or suppress with --no-items.
_spec=""
if [ "${1:-}" = "--no-items" ]; then
    shift
elif [ -n "${1:-}" ] && [ "${1:-}" != "--" ] && [ "${1:-}" != "--no-build" ]; then
    _spec="$1"; shift
elif [ -n "${START_ROOM:-}" ]; then
    _spec="$(python3 tools/room_items.py "$START_ROOM")"
    [ -n "$_spec" ] && echo "auto-items for room $START_ROOM: $_spec"
fi

if [ -n "$_spec" ]; then
    _n=0
    IFS=, read -ra _items <<<"$_spec"
    for _it in "${_items[@]}"; do
        case "$_it" in
            rope)     _f=14 ;;
            apple)    _f=17 ;;
            whiskey)  _f=18 ;;
            jug)      _f=19 ;;
            loaf)     _f=20 ;;
            railing)  _f=192 ;;
            *) echo "play.sh: unknown item '$_it' (rope apple whiskey jug loaf railing)" >&2; exit 2 ;;
        esac
        _n=$((_n+1))
        [ "$_n" -gt 3 ] && { echo "play.sh: at most 3 items (inv_cap is 3)" >&2; exit 2; }
        export "START_ITEM$_n=$_f"
    done
fi
if [ "${1:-}" = "--" ]; then shift; fi

if [ "$BUILD" = "1" ]; then
    # MUST go through stage_pack.sh, not a bare lwasm (T0095). The staged
    # $8000 blocks are LZSS-packed and packing is a two-pass build: the raw
    # pass generates the blobs and staged_syms.asm that the packed pass
    # consumes. A bare `lwasm --decb room36.asm` now REFUSES to assemble,
    # deliberately -- before that guard existed it emitted a binary whose
    # staging block A ran 2275 bytes into the $5800 gap holding the dizzy
    # frame tail, the message VM and the font. It assembled clean, loaded,
    # and died on boot.
    if [ "$FLOPPY" = "1" ]; then
        tools/floppy_pack.sh
    else
        tools/stage_pack.sh
        if [ "$TAPE" = "1" ]; then tools/tape_pack.sh; fi
    fi
elif [ "$FLOPPY" = "1" ] && [ ! -f target/dizzy.dsk ]; then
    echo "play.sh: --floppy --no-build needs an already-built target/dizzy.dsk" >&2
    exit 2
elif [ "$TAPE" = "1" ] && [ ! -f target/room36.cas ]; then
    echo "play.sh: --tape --no-build needs an already-built target/room36.cas" >&2
    exit 2
fi

# PLAY_GDB=1 opens xroar's gdb stub so tools/coords.py can read Dizzy's
# live room/x/y out of RAM -- for answering "where exactly were you
# standing?" with two numbers instead of a guess from a screenshot.
GDBARGS=""
if [ "${PLAY_GDB:-0}" = 1 ]; then
    GDBARGS="-gdb -gdb-port ${PLAY_GDB_PORT:-21000}"
    echo "gdb stub on ${PLAY_GDB_PORT:-21000} -- run: python3 tools/coords.py"
fi
if [ "$FLOPPY" = "1" ]; then
    echo "play.sh: --floppy -- LOADM\"DIZZY\":EXEC from target/dizzy.dsk (T0241)"
    exec xroar -machine coco2bus \
        -rompath source/roms -bas BASIC.ROM -extbas EXTBASIC.ROM \
        -cart rsdos -cart-type rsdos -cart-rom DSKBASIC.ROM \
        $GDBARGS -load-fd0 target/dizzy.dsk -type 'LOADM"DIZZY":EXEC'$'\r' "$@"
fi
if [ "$TAPE" = "1" ]; then
    echo "play.sh: --tape -- ONE CLOADM+EXEC from target/room36.cas (T0228)"
    exec xroar -machine coco2bus \
        -rompath source/roms -bas BASIC.ROM -extbas EXTBASIC.ROM \
        $GDBARGS -load-tape target/room36.cas -type "CLOADM"$'\r'"EXEC"$'\r' "$@"
fi
exec xroar -machine coco2bus \
    -rompath source/roms -bas BASIC.ROM -extbas EXTBASIC.ROM \
    $GDBARGS -run target/room36.bin "$@"
