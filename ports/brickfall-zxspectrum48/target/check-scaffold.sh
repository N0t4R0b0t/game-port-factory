#!/usr/bin/env bash
# Proof that `gpfdiff init-oracle` is useful: scaffold a black-box oracle for the ZX Brickfall (treated as an unknown
# original), make ONLY the edits a user makes, and demand it records exactly the reference model's goldens.
#
# The user's edits, and nothing else:
#   - the image path (`--image`),
#   - the keys this game reads (Z = left, X = right; the scaffold's defaults are the common O / P),
#   - the ready gate (a raw address, found with `gpfdiff watch --no-gate`; here PREV_BY from brickfall.sym),
#   - the field map: the real addresses (literals taken from brickfall.sym) for the 11 golden columns,
#   - `recipe`: where the scenarios are (the scaffold's own scenarios/ is for the user's game).
# Then: `check --list`, `capture` (== golden at every sample, determinism gate included) and a `check` with
# `[oracle] source = "trace"` (the commented example of the scaffold, made live).
#
# Env (set by the Makefile): GPFDIFF, MAME, ZX_ROMPATH (optional). Run from the target/ directory.
set -u
here=$(cd "$(dirname "$0")" && pwd)
GPFDIFF=${GPFDIFF:-$here/../../../factory/tools/gpfdiff/target/release/gpfdiff}
MAME=${MAME:-mame}
RECIPE=$(cd "$here/../../../games/brickfall/recipe" && pwd)
SNA=$here/brickfall.sna
SYM=$here/brickfall.sym
EMU=(--mame "$MAME")
[ -n "${ZX_ROMPATH:-}" ] && EMU+=(--rompath "$ZX_ROMPATH")
fail() { echo "FAIL: $*"; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
O=$T/oracle

sym() { awk -v n="$1:" '$1==n {print $3}' "$SYM"; }     # `name: equ 0x0000F000` -> 0x0000F000
STATE=$(( $(sym gpf_state) )); BRICKS=$(( $(sym gpf_bricks) )); GATE=$(( $(sym PREV_BY) ))
[ "$STATE" -gt 0 ] && [ "$BRICKS" -gt 0 ] && [ "$GATE" -gt 0 ] || fail "gpf_state / gpf_bricks / PREV_BY not found in $SYM"
hex() { printf '0x%04X' "$1"; }

"$GPFDIFF" init-oracle "$O" --platform zx48 --image "$SNA" || fail "init-oracle"
"$GPFDIFF" init-oracle "$O" --platform zx48 >"$T/again.txt"; [ $? -eq 2 ] && grep -q 'refusing to overwrite' "$T/again.txt" || fail "a second init-oracle must refuse to overwrite (exit 2)"

# ---- the user's edits
H=$O/harness.toml
sed -i -e 's|^LEFT  = "O"|LEFT  = "Z"|' -e 's|^RIGHT = "P"|RIGHT = "X"|' "$H"
grep -q '^LEFT  = "Z"' "$H" && grep -q '^RIGHT = "X"' "$H" || fail "the scaffold's [input.keys] layout changed"
sed -i "s|^#> ready = .*|ready = { addr = $(hex $GATE), in = [1, 254] }|" "$H"
sed -i "s|^recipe   = \".\".*|recipe   = \"$RECIPE\"|" "$H"
sed -i '/^\[\[field\]\]/,$d' "$H"                           # drop the placeholder fields (last in the file) ...
{
  field() { printf '[[field]]\nname = "%s"\naddr = %s\n%s\n' "$1" "$(hex $(( STATE + $2 )))" "${3:-}"; }
  field step     0x0 'size = 2'
  field mode     0x2
  field lives    0x3
  field score    0x4 'size = 2'
  field paddle_x 0x6
  field cleared  0x7
  field ball_x   0x8 'size = 2'
  field ball_y   0xA 'size = 2'
  field ball_vx  0xC $'size = 2\nsigned = true'
  field ball_vy  0xE $'size = 2\nsigned = true'
  printf '[[field]]\nname = "bricks"\naddr = %s\nsize = 5\nformat = "hex"\n' "$(hex "$BRICKS")"
} >>"$H"                                                    # ... and write the real 11-column map

# ---- 1. it parses and lists the recipe scenarios
n=$("$GPFDIFF" check "$O" --list | wc -l); [ "$n" -eq 11 ] || fail "check --list found $n scenarios, expected 11"

# ---- 2. capture == golden at every sample
mkdir "$T/cap"
"$GPFDIFF" capture "$O" --out "$T/cap" --repeat 2 "${EMU[@]}" || fail "capture"
ok=0
for g in "$RECIPE"/golden/*.trace; do
  s=$(basename "$g" .trace)
  [ -f "$T/cap/$s.trace" ] || fail "$s: not captured"
  if diff <(grep -v '^#' "$T/cap/$s.trace") <(grep -v '^#' "$g") >"$T/d.txt"; then ok=$((ok+1)); else echo "$s differs from the golden:"; head -5 "$T/d.txt"; fail "$s: capture != golden"; fi
done
[ "$ok" -eq 11 ] || fail "only $ok/11 scenarios equal their golden"
echo "scaffold capture == golden at every sample: $ok/11 scenarios"

# ---- 3. check with the scaffold's own [oracle] example made live (source = "trace"): the captured traces are the oracle
printf '\n[oracle]\nsource = "trace"\ndir    = "%s"\n' "$T/cap" >>"$H"
out=$("$GPFDIFF" check "$O" --only launch_left,speedup --no-canary "${EMU[@]}" 2>&1); rc=$?
echo "$out" | tail -3
[ "$rc" -eq 0 ] && echo "$out" | grep -q 'CHECK PASS: 2/2' || fail "check against the captured oracle (exit $rc)"
echo "CHECK-SCAFFOLD PASS"
