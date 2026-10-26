#!/usr/bin/env bash
# T0255 verifier: room-by-room fidelity of the port against the ZX original.  A cheaper tier can run this and read the last line:
# "VERIFY_ROOMCMP255 PASS" (exit 0) or "VERIFY_ROOMCMP255 FAIL: ..." (exit 1, the game differs) / exit 2 (environment).
#   NOBUILD=1 tools/verify_roomcmp255.sh        # reuse target/ as built (the default builds the tape image twice first)
#   QUICK=1  tools/verify_roomcmp255.sh         # skip the two bot runs: reuse the entry states and logs of the last full run
# Steps (all sequential; emulators run one at a time):
#   1. tools/tape_pack.sh x2 (unless NOBUILD)         2. the comparer's canary (cargo test)
#   3. message streams == X-ALL.TXT byte for byte: verify_tape_text (28 tape streams) and verify_base_text (42 base streams)
#   4. tools/roomcmp.sh --entries (both bots, 48 rooms x 2 machines recorded twice, the visits comparison) -> ROOMCMP PASS
#   5. tools/hazardcmp.sh on the static-hazard rooms 24 35 45 46 48 51 60 77 94 (where Dizzy dies must agree up to edge noise)
set -uo pipefail
cd "$(dirname "$0")/.."
fails=(); note(){ echo "-- $*"; }; bad(){ fails+=("$1"); echo "   FAIL: $1"; }
if [ -z "${NOBUILD:-}" ] && [ -z "${QUICK:-}" ]; then
  tools/tape_pack.sh > /tmp/verify_roomcmp255_pack1.log 2>&1 || bad "tape_pack.sh run 1"
  tools/tape_pack.sh > /tmp/verify_roomcmp255_pack2.log 2>&1 || bad "tape_pack.sh run 2"
  grep -E 'persistent FREE' /tmp/verify_roomcmp255_pack2.log
fi
note "canary: cargo test (equal data MATCH, shifted PHASE, one changed value DIVERGE)"
cargo test -q --manifest-path tools/roomcmp/Cargo.toml 2>&1 | grep -q '^test result: ok' || bad "roomcmp cargo test"
note "message streams against X-ALL.TXT"
tools/roompack/target/release/verify_tape_text | tail -1 | grep -q 'VERIFY_TAPE_TEXT PASS' || bad "verify_tape_text"
tools/roompack/target/release/verify_base_text | tail -1 | grep -q 'unexpected=0' || bad "verify_base_text"
note "tools/roomcmp.sh (this takes ~12 minutes with --entries)"
if [ -n "${QUICK:-}" ]; then ARGS=""; else ARGS="--entries"; fi
tools/roomcmp.sh $ARGS --no-selftest > /tmp/verify_roomcmp255_cmp.log 2>&1; rc=$?
tail -3 /tmp/verify_roomcmp255_cmp.log
[ $rc = 0 ] || bad "roomcmp.sh exit $rc (/tmp/verify_roomcmp255_cmp.log)"
note "hazard sweeps (where Dizzy dies), static hazards"
for r in 24 35 45 46 48 51 60 77 94; do
  out=$(tools/hazardcmp.sh $r 2>&1 | grep '^HAZARDCMP' | tail -1); echo "   room $r: $out"
  echo "$out" | grep -q 'SAME' || bad "hazardcmp room $r"
done
if [ ${#fails[@]} -eq 0 ]; then echo "VERIFY_ROOMCMP255 PASS"; exit 0; fi
echo "VERIFY_ROOMCMP255 FAIL: ${fails[*]}"; exit 1
