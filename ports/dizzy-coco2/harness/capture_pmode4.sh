#!/usr/bin/env bash
# Headless PMODE4 framebuffer capture: boot xroar, run a target binary,
# wait, pull the 6144-byte graphics framebuffer out over the GDB stub,
# decode to PNG. Companion to capture.sh (which does the same for the
# 32x16 text/alpha screen) -- use this one for anything that sets up
# PMODE4 graphics mode itself (see target/room36.asm).
#
# !! THIS CANNOT VERIFY WHAT THE SCREEN ACTUALLY SHOWS. !!
# It decodes $4000 as 1bpp 256x192 -- i.e. it assumes the very thing a
# video-mode check would test. If the VDG is in the wrong mode, this still
# renders a perfect picture. That is not hypothetical: a wrong PIA1 mode
# nibble left this port displaying CG6 (128x192, 4 colour, 2bpp) instead of
# PMODE4 for days while this script stayed green, and a human's screenshot
# of the real (bad) output got written off as a display-environment issue.
# See NOTES.md T0028.
#
# Use this to check "did the blit write the right bytes?".
# Use harness/capture_display.sh to check "does the machine SHOW it right?".
# Any claim about how the game LOOKS needs the second one.
#
# Assumes the target's framebuffer lives at $4000 (this port's convention
# so far, see NOTES.md "Slice: room 36") -- pass a different address as
# $3 if a program uses a different one.
#
# Usage: capture_pmode4.sh BINARY.bin OUT.png [FB_ADDR_HEX] [WAIT_SECONDS]
set -euo pipefail
cd "$(dirname "$0")"

BIN="${1:?usage: capture_pmode4.sh BINARY.bin OUT.png [FB_ADDR_HEX] [WAIT_SECONDS]}"
OUT="${2:?usage: capture_pmode4.sh BINARY.bin OUT.png [FB_ADDR_HEX] [WAIT_SECONDS]}"
FB_ADDR="${3:-4000}"
WAIT="${4:-2}"
ROMS="../source/roms"
PORT=$((20000 + RANDOM % 40000))  # avoid colliding with a lingering prior instance

xroar -ui null -machine coco2bus \
    -rompath "$ROMS" -bas BASIC.ROM -extbas EXTBASIC.ROM \
    -run "$BIN" -no-ratelimit \
    -gdb -gdb-port "$PORT" > /tmp/dizzy-coco2-pmode4-capture.log 2>&1 &
XR_PID=$!
trap 'kill $XR_PID 2>/dev/null || true' EXIT

sleep "$WAIT"

python3 gdbmem.py 127.0.0.1 "$PORT" "$FB_ADDR" 6144 | python3 pmode4_to_png.py /dev/stdin "$OUT"
