#!/usr/bin/env bash
# Pure-text guard for the public text templates. Needs NO user data.
#
# Every string-bearing directive (fcc fcs fcn .ascii .asciz .string) in the given template dirs must have
# exactly one operand that is either an @orig(TAG:LINE[#N]/LEN) key or one of the strings in port_only.txt.
# fcb/fdb operands must not contain a quote or character literal (no text smuggled in as bytes).
# Anything else exits 1, so a future edit that pastes original text into a template fails closed, even
# on a machine that has no copy of the game.
#
# Usage: tools/textsplit/check_templates.sh [--port-only FILE] DIR...   (run from anywhere; paths as given)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PO="$HERE/port_only.txt"
if [ "${1:-}" = "--port-only" ]; then PO=${2:?}; shift 2; fi
[ $# -ge 1 ] || { echo "usage: check_templates.sh [--port-only FILE] DIR..." >&2; exit 2; }
[ -s "$PO" ] || { echo "check_templates: port-only list '$PO' missing or empty" >&2; exit 2; }
n=0
for d in "$@"; do
  [ -d "$d" ] || { echo "check_templates: template dir '$d' missing" >&2; exit 2; }
  for f in "$d"/*.asm; do
    [ -f "$f" ] || { echo "check_templates: no .asm in '$d'" >&2; exit 2; }
    n=$((n+1))
    awk -v po="$PO" -v file="$f" '
      BEGIN { while ((getline l < po) > 0) { sub(/[ \t\r]+$/, "", l); if (l != "" && l !~ /^#/) ok[l]=1 } }
      { line=$0; sub(/\r$/, "", line)
        if (match(line, /^([A-Za-z_.$][A-Za-z_0-9.$]*:?)?[ \t]+[.]?[A-Za-z]+([ \t]|$)/) == 0) next
        t=line; sub(/^([A-Za-z_.$][A-Za-z_0-9.$]*:?)?[ \t]+/, "", t)
        op=t; sub(/^[.]?[A-Za-z]+[ \t]*/, "", op); d=tolower(t); sub(/[ \t].*$/, "", d)
        if (d ~ /^(fcc|fcs|fcn|[.]ascii|[.]asciz|[.]string)$/) {
          if (op ~ /^"@orig\([A-Za-z0-9_-]+:[0-9]+(#[0-9]+)?\/[0-9]+\)"[ \t]*(;.*)?$/) next
          if (match(op, /^"[^"]*"/)) { s=substr(op, 2, RLENGTH-2); rest=substr(op, RLENGTH+1)
            if ((s in ok) && rest ~ /^[ \t]*(;.*)?$/) next }
          printf "FAIL %s:%d: string operand is neither an @orig key nor a port_only.txt string: %s\n", file, NR, line; bad=1
        } else if (d ~ /^(fcb|fdb|[.]byte|[.]word)$/) {
          sub(/;.*$/, "", op)
          if (op ~ /["\x27]/) { printf "FAIL %s:%d: quote/char literal in %s operand: %s\n", file, NR, d, line; bad=1 }
        } }
      END { exit bad }' "$f" || rc=1
  done
done
[ "${rc:-0}" = 0 ] || exit 1
echo "check_templates: OK ($n template files; only @orig keys and port_only.txt strings)"
