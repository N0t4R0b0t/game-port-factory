#!/usr/bin/env bash
# Run the ORIGINAL ZX Spectrum Fantasy World Dizzy in MAME, headless, and
# capture snapshots — the reference the CoCo2 port is compared against.
#
# Boots from a savestate parked in room 36 (the room being ported), so a
# run costs ~5 emulated seconds instead of the ~7 emulated MINUTES a tape
# load takes. Rebuild the state with `--from-tape` if it ever goes stale
# (MAME savestates are tied to a MAME version — 0.289 when this was made;
# a MAME upgrade may invalidate it, and the symptom is a load that leaves
# a blank or garbage screen rather than a clean error).
#
# ALWAYS headless (-video none). Do NOT add -window: snapshots work fine
# without it, and a window opens on the user's actual desktop.
#
# Media (BIOS ROM + savestate, both derived from the user's own media)
# lives under source/zx/, which .gitignore keeps out of the repo.
#
# !! STALE AS OF 2026-09-12 (dizzy-coco2 T0108 work): room36.sta loads, shows
# the dungeon for about ONE SECOND, then the machine COLD-RESETS. Measured
# from Lua, nonzero bytes in $5C00-$FFFF after the load: 35345 at frame
# 40, 18837 at 60, 2197 at 80, 237 at 100 -- the 48K ROM's RAM test
# sweeping memory. A snapshot at frame 25 therefore still LOOKS right,
# which is how this went unnoticed; anything scripted after ~1s runs
# against a BASIC boot (key presses become BASIC key clicks). Rebuild with
# --from-tape, or do the tape load inside the same run and skip savestates
# entirely (a tape load under -nothrottle is ~10s real time).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="$(dirname "$HERE")"
ROMPATH="$PORT/source/zx/roms"
STATE="$PORT/source/zx/state/room36.sta"
TAPE="$PORT/source/Dizzy III - Fantasy World Dizzy (1989)(Codemasters).tzx"
OUT="${ZX_OUT:-/tmp/zxsnap}"
SECS="${ZX_SECONDS:-5}"
KEYS="${ZX_KEYS:-}"       # e.g. "p" — held via the Lua script below
SNAPNAME="${ZX_SNAPNAME:-zx%i}"

# NOTE: the research/*.tap of this game is CORRUPT (MAME: "wrong checksum",
# "block #49 required 18504 byte(s), but only 14859 available"). Use the
# source/*.tzx — it loads clean.
if [[ "${1:-}" == "--from-tape" ]]; then
  mkdir -p "$(dirname "$STATE")"
  cat > /tmp/zx_fromtape.lua <<'LUA'
local cass = manager.machine.cassettes[":cassette"]
local nk = manager.machine.natkeyboard
local f = 0
emu.register_periodic(function()
  f = f + 1
  -- natkeyboard:post is what actually types; -autoboot_command did NOT
  -- work on this driver even with -natural. 'j' is the LOAD keyword.
  if f == 120   then nk:post('j""\n') end
  if f == 200   then cass:play() end
  if f == 21600 then cass:stop(); nk:post(' ') end   -- title: SPC to start
  if f == 22000 then manager.machine:save(os.getenv("ZX_STATE")) print("SAVED") end
end)
LUA
  ZX_STATE="$STATE" mame spectrum -rompath "$ROMPATH" -cass "$TAPE" \
    -autoboot_script /tmp/zx_fromtape.lua \
    -video none -sound none -nothrottle -seconds_to_run 445 2>&1 | grep -v load_dat
  echo "state written: $STATE"
  exit 0
fi

mkdir -p "$OUT"
cat > /tmp/zx_run.lua <<'LUA'
local f = 0
local keys = os.getenv("ZX_KEYS") or ""
emu.register_periodic(function()
  f = f + 1
  if f == 5 then manager.machine:load(os.getenv("ZX_STATE")) end
  if f > 20 and keys ~= "" then manager.machine.natkeyboard:post(keys) end
  if f > 20 and f % 25 == 0 then manager.machine.video:snapshot() end
end)
LUA
# NOT -nothrottle here (T0037): on this driver, combined with -video
# none, register_periodic's callback stops firing almost immediately
# under -nothrottle (confirmed with a bare tick counter -- it reached
# f=21 or so and then nothing, no matter how large -seconds_to_run was,
# with no error printed). Without -nothrottle it ticks at the expected
# ~50/sec (PAL) and -seconds_to_run behaves as documented. Runs cost
# roughly 1 real second per emulated second as a result -- fine for a
# few seconds of scripted movement, unlike the ~7-minute tape load
# above (which is why that path keeps -nothrottle; it was never
# re-tested for this bug and isn't worth the risk of touching a savestate
# that already works).
ZX_STATE="$STATE" ZX_KEYS="$KEYS" mame spectrum -rompath "$ROMPATH" \
  -autoboot_script /tmp/zx_run.lua \
  -snapshot_directory "$OUT" -snapname "$SNAPNAME" \
  -video none -sound none -seconds_to_run "$SECS" 2>&1 | grep -v load_dat || true
echo "snapshots in $OUT:"; ls "$OUT" | tail -5
