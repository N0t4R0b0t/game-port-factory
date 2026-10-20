#!/usr/bin/env bash
# Headless capture: boot xroar with a target binary, wait, pull screen memory
# out over the GDB stub, decode to text. No GUI, no screenshot tooling
# required — proven necessary in this sandbox (Xvfb+`import` gives back a
# blank frame for xroar's GL-rendered window; see NOTES.md "RESOLVED" entry
# under Dead ends). Run this on the dev machine for automated/unattended
# checks; use a real xroar window on a real desktop for visual sign-off.
#
# Usage: capture.sh BINARY.bin [WAIT_SECONDS]
set -euo pipefail
cd "$(dirname "$0")"

BIN="${1:?usage: capture.sh BINARY.bin [WAIT_SECONDS]}"
WAIT="${2:-2}"
ROMS="../source/roms"
PORT=65520

xroar -ui null -machine coco2bus \
    -rompath "$ROMS" -bas BASIC.ROM -extbas EXTBASIC.ROM \
    -run "$BIN" -no-ratelimit \
    -gdb -gdb-port "$PORT" > /tmp/dizzy-coco2-capture.log 2>&1 &
XR_PID=$!
trap 'kill $XR_PID 2>/dev/null || true' EXIT

# give xroar time to boot + the program time to run before connecting once —
# repeated connect/disconnect probes against the gdb stub were observed to
# leave it unable to serve the real client afterwards, so don't probe.
sleep "$WAIT"

python3 gdbmem.py 127.0.0.1 "$PORT" 400 200 | python3 screen_text.py
