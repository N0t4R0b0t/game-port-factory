#!/usr/bin/env bash
# Build the Dizzy CoCo2 port from a clone plus the files YOU supply (tools/inputs.toml).
#
# Verifies every input by sha256, copies them to where the tools expect them (all gitignored),
# builds the Rust tools offline, then runs the generators in docs/PROVENANCE.md order. It never
# downloads anything. With --verify the five final artifacts are compared with
# docs/BUILD-HASHES.txt.
#
# Usage: tools/bootstrap.sh [--d3 DIR] [--roms DIR] [--steps a,b,c] [--verify] [--list] [--force] [-v]
#   --d3 DIR      your picosonic/D3 checkout (contains original_source/ and info/); copied into
#                 research/D3-prior-art/. Omit if the files are already there.
#   --roms DIR    dir with BASIC.ROM, EXTBASIC.ROM, DSKBASIC.ROM (run-only; not needed to build)
#   --steps LIST  comma-separated subset, run in the given order (see --list). Default: all.
#   --verify      after the steps, compare the five artifacts with docs/BUILD-HASHES.txt
#   --list        print the steps and exit
#   --force       re-copy inputs even when the destination already matches
#   -v            stream each step's output instead of only logging it
# Step logs: target/bootstrap_logs/NN-<step>.log (gitignored).
set -euo pipefail
PORT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PORT"

INPUTS=tools/inputs.toml
HASHES=docs/BUILD-HASHES.txt
LOGDIR=target/bootstrap_logs
OS=research/D3-prior-art/original_source       # where the tools expect the D3 sources
ARTIFACTS=(target/room36.bin target/room36_tape.bin target/room36_floppy.bin target/room36.cas target/dizzy.dsk)
RUST_TOOLS=(roomdata actordata spritedata textdata textsplit aycapture roompack dte caswriter dskwriter)

STEPS_ALL=(inputs tools extract split sounds seed art fill_text harness_text dte stage tape floppy)
declare -A DESC=(
    [inputs]="verify user-supplied inputs by sha256, copy them into place"
    [tools]="cargo build --release --offline: ${RUST_TOOLS[*]}"
    [extract]="roomdata, actordata, spritedata frmtable + dizzy-pack-all, textdata -> extracted/*.json (incl. game_text.json), target/dizzy_frames_all.asm"
    [split]="tools/dizzy_split/split.sh: dizzy_frames_all.asm -> bodyA/bodyB/tail"
    [sounds]="tools/mksounds.sh: Z80-sandbox captures -> sound_data.asm, mix3_stream.asm"
    [seed]="create placeholder title_* files so stage_pack's first raw pass can assemble (only where absent)"
    [art]="tools/regen_art.sh: roompack -> room*_data, font, shared_*, frame_table, actor_data"
    [fill_text]="textsplit fill: text_tpl* (public templates) + extracted/game_text.json (your text) -> text_src*"
    [harness_text]="textsplit export-lua: extracted/game_text.json -> harness/orig_text.lua (the original's strings as a Lua table; harness fixture, gitignored)"
    [dte]="tools/dte build: DTE-encode text_src* -> gameplay, gap_messages, actors, msg_data_*, dte_table"
    [stage]="tools/stage_pack.sh for the three variants: -run (TAPE_ROOMS=0), tape (TAPE_ROOMS=1), floppy (FLOPPY=1)"
    [tape]="tools/tape_pack.sh -> room36.cas"
    [floppy]="tools/floppy_pack.sh -> dizzy.dsk"
    [verify]="compare the five artifacts with $HASHES, scan generated files for absolute personal paths"
)

D3="" ROMS="" STEPS_ARG="" DO_VERIFY=0 FORCE=0 VERBOSE=0 LIST=0
while [ $# -gt 0 ]; do
    case "$1" in
        --d3)    D3="${2:?--d3 needs a directory}"; shift 2 ;;
        --roms)  ROMS="${2:?--roms needs a directory}"; shift 2 ;;
        --steps) STEPS_ARG="${2:?--steps needs a comma-separated list}"; shift 2 ;;
        --verify) DO_VERIFY=1; shift ;;
        --list)  LIST=1; shift ;;
        --force) FORCE=1; shift ;;
        -v|--verbose) VERBOSE=1; shift ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "bootstrap.sh: unknown argument '$1' (see --help)" >&2; exit 2 ;;
    esac
done

if [ $LIST = 1 ]; then
    i=0
    for s in "${STEPS_ALL[@]}" verify; do
        i=$((i+1)); printf '%2d  %-9s %s\n' "$i" "$s" "${DESC[$s]}"
    done
    echo "(verify runs only with --verify or --steps ...,verify)"
    exit 0
fi

if [ -n "$STEPS_ARG" ]; then IFS=, read -ra STEPS <<<"$STEPS_ARG"; else STEPS=("${STEPS_ALL[@]}"); fi
[ $DO_VERIFY = 1 ] && STEPS+=(verify)
for s in "${STEPS[@]}"; do
    [ -n "${DESC[$s]:-}" ] || { echo "bootstrap.sh: unknown step '$s' (see --list)" >&2; exit 2; }
done

[ -f "$INPUTS" ] || { echo "bootstrap.sh: $INPUTS not found" >&2; exit 1; }

# ---- inputs ----------------------------------------------------------------------------------
# inputs.toml -> TSV: id group path dest sha256 required get
inputs_tsv() {
    awk '
    function emit() { if (id != "") printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", id, group, path, dest, sha, req, get }
    /^\[\[input\]\]/ { emit(); id=group=path=dest=sha=req=get=""; intable=1; next }
    /^\[/            { emit(); id=""; intable=0; next }
    intable && /^[a-z0-9_]+[ ]*=/ {
        k=$0; sub(/[ ]*=.*/, "", k)
        v=$0; sub(/^[^=]*=[ ]*"/, "", v); sub(/"[ ]*$/, "", v)
        if (k=="id") id=v; else if (k=="group") group=v; else if (k=="path") path=v
        else if (k=="dest") dest=v; else if (k=="sha256") sha=v; else if (k=="required") req=v
        else if (k=="get") get=v
    }
    END { emit() }' "$INPUTS"
}
sha_of() { sha256sum "$1" | cut -d' ' -f1; }

# verify_inputs copy|check -- copy mode honours --d3/--roms; check mode only looks at what is in place.
verify_inputs() {
    local mode=$1 errs=0 warns=0
    local id group path dest sha req get src root got
    while IFS=$'\t' read -r id group path dest sha req get; do
        root=""
        case "$group" in d3) root="$D3" ;; rom) root="$ROMS" ;; esac
        if [ "$mode" = copy ] && [ -n "$root" ]; then
            src="$root/$path"
            if [ ! -f "$src" ]; then
                echo "ERROR: $id: '$path' not found under '$root'. Where to get it: $get" >&2; errs=$((errs+1)); continue
            fi
            got=$(sha_of "$src")
            if [ "$got" != "$sha" ]; then
                echo "ERROR: $id: '$src' has sha256 $got, expected $sha (modified or a different version). Where to get it: $get" >&2
                errs=$((errs+1)); continue
            fi
            if [ $FORCE = 1 ] || [ ! -f "$dest" ] || [ "$(sha_of "$dest")" != "$sha" ]; then
                if [ -e "$dest" ] && [ "$src" -ef "$dest" ]; then :; else
                    mkdir -p "$(dirname "$dest")"; cp -f "$src" "$dest"; echo "  copied  $id -> $dest"
                fi
            else
                echo "  ok      $id (already in place)"
            fi
            continue
        fi
        # in-place check
        if [ -f "$dest" ]; then
            got=$(sha_of "$dest")
            if [ "$got" = "$sha" ]; then echo "  ok      $id ($dest)"; continue; fi
            case "$group" in
                d3|rom) echo "ERROR: $id: '$dest' has sha256 $got, expected $sha (modified or a different version). Where to get it: $get" >&2
                        errs=$((errs+1)) ;;
                *)      echo "  WARN    $id: '$dest' has sha256 $got, expected $sha (harness-only; ignored)" >&2; warns=$((warns+1)) ;;
            esac
        else
            case "$group" in
                d3) echo "ERROR: $id: missing '$dest'. Pass --d3 DIR (your picosonic/D3 checkout) or place it there. Where to get it: $get" >&2
                    errs=$((errs+1)) ;;
                rom) echo "  skip    $id: absent (run-only ROM; pass --roms DIR to install). Where to get it: $get" ;;
                *)   echo "  absent  $id (harness-only, optional)" ;;
            esac
        fi
    done < <(inputs_tsv)
    if [ $errs -gt 0 ]; then
        echo "bootstrap.sh: $errs required input problem(s); nothing was downloaded or modified beyond the copies above." >&2
        return 1
    fi
}

# ---- toolchain check -------------------------------------------------------------------------
for c in lwasm python3 cargo sha256sum awk; do
    command -v "$c" >/dev/null 2>&1 || { echo "bootstrap.sh: '$c' not found on PATH (needed to build)" >&2; exit 1; }
done

# private scratch dir for the build scripts' /tmp files (GPF_TMP), so two builds never collide
GPF_TMP=$(mktemp -d "${TMPDIR:-/tmp}/gpf-dizzy-bootstrap.XXXXXX")
export GPF_TMP
trap 'rm -rf "$GPF_TMP"' EXIT
export CARGO_NET_OFFLINE=true
mkdir -p "$LOGDIR" extracted target

# ---- steps -----------------------------------------------------------------------------------
step_tools() {
    local t
    for t in "${RUST_TOOLS[@]}"; do
        echo "-- cargo build $t"
        cargo build --release --offline --manifest-path "tools/$t/Cargo.toml" || {
            echo "bootstrap.sh: offline build of $t failed. If its crates are not in the local cargo cache, run" >&2
            echo "  cargo fetch --manifest-path tools/$t/Cargo.toml   (needs network, once) and re-run." >&2
            return 1; }
    done
}

step_extract() {
    mkdir -p extracted
    # Relative paths on purpose: the tools echo their input path into the JSON (source_file).
    tools/roomdata/target/release/roomdata --input $OS/ROOMDATA.DAT --names research/D3-prior-art/info/rooms \
        --output extracted/rooms.json --verify
    tools/actordata/target/release/actordata --source $OS/X-ALL.TXT --output extracted/actors.json
    tools/spritedata/target/release/spritedata frmtable $OS/FRAMES.DAT --output extracted/frmtable.json
    tools/spritedata/target/release/spritedata dizzy-pack-all $OS/DIZZYFRM.DAT --output target/dizzy_frames_all.asm
    # The game's text, from YOUR X-ALL.TXT / PRTDIZZY.PDS (relative paths, same order as the pinned output).
    tools/textdata/target/release/textdata $OS/PRTDIZZY.PDS $OS/X-ALL.TXT --output extracted/game_text.json
    if grep -l '/home/\|/Users/\|"source_file": *"/' extracted/rooms.json extracted/actors.json extracted/frmtable.json extracted/game_text.json; then
        echo "bootstrap.sh: absolute path leaked into extracted/*.json" >&2; return 1
    fi
}

step_split()  { tools/dizzy_split/split.sh target/dizzy_frames_all.asm target; }
step_sounds() { tools/mksounds.sh; }
# stage_pack.sh's raw pass INCLUDES target/title_*.asm, which mktitle only writes later in the same
# run (NOTES.md T0224 "run it twice"). A clone has none of them, so give the first pass comment-only
# placeholders; room36.asm carries fallbacks for all missing equates except TITLE_LZ_LEN, which the placeholder defines. The real files replace them
# in the first stage_pack run and the second run (step `stage` runs every variant three times) settles.
step_seed() {
    local f s
    # (_floppy ones are seeded by stage_pack.sh itself, by copying the tape build's real files)
    for s in "" _tape; do
        [ -f "target/title_lz$s.asm" ] || { echo "; bootstrap seed: placeholder, rewritten by mktitle (tools/stage_pack.sh)" > "target/title_lz$s.asm"; echo "seeded target/title_lz$s.asm"; }
        [ -f "target/title_frags$s.asm" ] || {
            printf '%s\n' "; bootstrap seed: placeholder, rewritten by mktitle (tools/stage_pack.sh)" "title_frags" "        fdb 0,0" "TITLE_LZ_LEN equ 3000" > "target/title_frags$s.asm"
            echo "seeded target/title_frags$s.asm"; }
    done
    # the tape/floppy builds also read the resident title blob and its length
    [ -f target/title_resident_lz.asm ] || {
        printf '%s\n' "; bootstrap seed: placeholder, rewritten by mktitle" "TITLE_RESIDENT_LEN equ TITLE_LZ_LEN+TITLE_MUSIC_LEN" "TITLE_RESIDENT_LZ" > target/title_resident_lz.asm
        echo "seeded target/title_resident_lz.asm"; }
}
step_art()    { REGEN_ART_NO_STAGE=1 tools/regen_art.sh; }

# The templates (target/text_tpl*, tracked) hold code, comments, port-only strings and @orig(...) keys;
# the original strings come from YOUR extracted/game_text.json. Missing text is a hard error, never a skip.
step_fill_text() {
    local d
    if [ ! -s extracted/game_text.json ]; then
        echo "bootstrap.sh: extracted/game_text.json is missing or empty." >&2
        echo "  It is made from your X-ALL.TXT / PRTDIZZY.PDS by the 'extract' step (textdata); run the" >&2
        echo "  'inputs' and 'extract' steps first (and supply --d3 DIR). Refusing to build without the game text." >&2
        return 1
    fi
    for d in "" _tape; do
        [ -d "target/text_tpl$d" ] || { echo "bootstrap.sh: template dir target/text_tpl$d is missing from the checkout" >&2; return 1; }
        rm -rf "target/text_src$d"
        tools/textsplit/target/release/textsplit fill --templates "target/text_tpl$d" \
            --orig-json extracted/game_text.json --out "target/text_src$d"
    done
}

# Harness scripts look original strings up by key ("X-ALL:733") instead of carrying them as literals.
step_harness_text() {
    [ -s extracted/game_text.json ] || { echo "bootstrap.sh: extracted/game_text.json is missing (run 'extract')" >&2; return 1; }
    tools/textsplit/target/release/textsplit export-lua --orig-json extracted/game_text.json --out harness/orig_text.lua
}

step_dte()   { tools/dte/target/release/dte --root . build; }
# Two settling passes (audits off) because the first raw pass reads placeholder title_*.asm and the
# tape/floppy builds seed each other (NOTES.md T0224/T0241 "run it twice"); then one audited pass.
step_stage() {
    local pass
    for pass in 1 2 3; do
        echo "-- stage_pack pass $pass$([ $pass -lt 3 ] && echo ' (settling, audits off)'): -run, tape, floppy"
        [ $pass -lt 3 ] && export STAGE_SETTLE=1 || unset STAGE_SETTLE
        TAPE_ROOMS=0 tools/stage_pack.sh
        TAPE_ROOMS=1 tools/stage_pack.sh
        FLOPPY=1     tools/stage_pack.sh
    done
}
step_tape()   { tools/tape_pack.sh; }
step_floppy() { tools/floppy_pack.sh; }

step_verify() {
    [ -f "$HASHES" ] || { echo "bootstrap.sh: $HASHES not found" >&2; return 1; }
    local bad=0 f want got
    for f in "${ARTIFACTS[@]}"; do
        want=$(awk -v f="$f" '$2 == f {print $1}' "$HASHES")
        [ -n "$want" ] || { echo "FAIL $f: no entry in $HASHES" >&2; bad=$((bad+1)); continue; }
        if [ ! -f "$f" ]; then echo "FAIL $f: not built" >&2; bad=$((bad+1)); continue; fi
        got=$(sha_of "$f")
        if [ "$got" = "$want" ]; then echo "  match   $f  $got"
        else echo "FAIL $f: sha256 $got, expected $want" >&2; bad=$((bad+1)); fi
    done
    # no personal absolute path in anything the bootstrap writes
    local leaks
    leaks=$(tools/clean_generated.sh 2>/dev/null | grep -v '^target/bootstrap_logs$' | xargs -d '\n' grep -rIl '/home/\|/Users/' 2>/dev/null || true)
    if [ -n "$leaks" ]; then echo "FAIL absolute personal path in generated file(s):" >&2; echo "$leaks" >&2; bad=$((bad+1))
    else echo "  clean   no '/home/' or '/Users/' in any generated file"; fi
    [ $bad -eq 0 ] || return 1
    echo "all ${#ARTIFACTS[@]} artifacts match $HASHES"
}

# ---- runner ----------------------------------------------------------------------------------
N=${#STEPS[@]}
inputs_done=0
for s in "${STEPS[@]}"; do [ "$s" = inputs ] && inputs_done=1; done
need_inputs=0
for s in "${STEPS[@]}"; do case "$s" in verify) ;; inputs) ;; *) need_inputs=1 ;; esac; done
if [ $inputs_done = 0 ] && [ $need_inputs = 1 ]; then
    echo "== pre-check: inputs in place"
    verify_inputs check >/dev/null || exit 1
fi

T_ALL=$(date +%s)
i=0
for s in "${STEPS[@]}"; do
    i=$((i+1))
    echo "== [$i/$N] $s: ${DESC[$s]}"
    t0=$(date +%s)
    if [ "$s" = inputs ]; then
        verify_inputs copy || exit 1
    else
        log="$LOGDIR/$(printf '%02d' "$i")-$s.log"
        set +e
        if [ $VERBOSE = 1 ]; then ( "step_$s" ) 2>&1 | tee "$log"; rc=${PIPESTATUS[0]}
        else ( "step_$s" ) >"$log" 2>&1; rc=$?; fi
        set -e
        if [ $rc -ne 0 ]; then
            [ $VERBOSE = 1 ] || { echo "-- last lines of $log:" >&2; tail -n 30 "$log" >&2; }
            echo "bootstrap.sh: step '$s' FAILED (exit $rc) after $(( $(date +%s) - t0 ))s; full log: $PORT/$log" >&2
            exit 1
        fi
        if [ "$s" = verify ] && [ $VERBOSE = 0 ]; then cat "$log"; fi
    fi
    echo "   ok ($(( $(date +%s) - t0 ))s)"
done
echo "bootstrap.sh: ${#STEPS[@]} step(s) done in $(( $(date +%s) - T_ALL ))s"
