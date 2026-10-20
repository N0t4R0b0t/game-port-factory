#!/usr/bin/env bash
# Data-free backstop for the text policy (docs/PROVENANCE.md "Text policy"). Needs NO user data.
#
# The original encodes its strings with ':' for a space, upper case, and a few punctuation stand-ins
# (; @ < > = & ?). Quoting running dialogue from the source almost always keeps that form
# ("HAVE:LOST:MY:HAT" style), so this scan FAILS on any run of >= 3 colon-joined upper-case segments in a tracked
# text file, unless the exact run is listed in nodata_allow.txt (room titles and item names, which are
# identifiers and may be named). Skipped: tools/textsplit/ (its tests hold invented strings; the user-data
# gate scans it anyway) and target/text_tpl*/ (check_templates.sh). Hex/number triples ("36:184:176", "V2:V1:V0") never match: digits end a run.
#
# LIMITATION: it cannot see dialogue written in plain words ("you give the apple to the troll").
# That is caught only by `textsplit check-public --docs`, which needs the user's game_text.json.
#
# Usage: check_docs_nodata.sh [--allow FILE] FILE...        exit 0 clean, 1 findings, 2 usage
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
AL="$HERE/nodata_allow.txt"
if [ "${1:-}" = "--allow" ]; then AL=${2:?}; shift 2; fi
[ $# -ge 1 ] || { echo "usage: check_docs_nodata.sh [--allow FILE] FILE..." >&2; exit 2; }
[ -f "$AL" ] || { echo "check_docs_nodata: allow list '$AL' missing" >&2; exit 2; }
rc=0; n=0
for f in "$@"; do
  [ -f "$f" ] || continue
  grep -Iq . "$f" 2>/dev/null || continue        # skip binary / empty
  case "$f" in                                    # skipped: textsplit's own sources (invented test strings) and the
    */tools/textsplit/*|*/target/text_tpl/*|*/target/text_tpl_tape/*) continue;; # templates (gated by check_templates.sh)
  esac
  n=$((n+1))
  awk -v allow="$AL" -v file="$f" '
    BEGIN { while ((getline l < allow) > 0) { sub(/[ \t\r]+$/, "", l); if (l != "" && l !~ /^#/) ok[l]=1 } }
    { line=$0; off=0
      while (match(line, /[A-Z:;@<>=&?\x27]+/)) {
        run=substr(line, RSTART, RLENGTH)
        pre=(RSTART>1)?substr(line, RSTART-1, 1):" "
        post=substr(line, RSTART+RLENGTH, 1)
        line=substr(line, RSTART+RLENGTH)
        if (pre ~ /[a-z0-9_]/ || post ~ /[a-z0-9_]/) continue
        segs=0; t=run; nseg=split(t, parts, ":")
        for (i=1;i<=nseg;i++) if (parts[i] ~ /[A-Z]/) segs++
        if (segs >= 3 && nseg-1 >= 2 && !(run in ok)) { printf "NODATA LEAK %s:%d: colon-encoded string run (%d segments): %s\n", file, NR, segs, run; bad=1 }
      } }
    END { exit bad }' "$f" || rc=1
done
[ $rc = 0 ] || { echo "check_docs_nodata: FAILED (colon-encoded original-style strings; quote identifiers by their plain name, dialogue by [X-ALL.TXT line N])" >&2; exit 1; }
echo "check_docs_nodata: OK ($n files, no colon-encoded string runs)"
