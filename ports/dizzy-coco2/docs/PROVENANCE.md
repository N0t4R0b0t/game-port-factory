# Provenance: where every build input comes from

Goal: a fresh clone of the public repo plus **material you supply yourself** builds the Dizzy
port. This file is the contract: what ships in the repo, what you supply, and what the
bootstrap generates. Paths are relative to `ports/dizzy-coco2/`. Audit date 2026-10-20.

## What you supply (never in the repo)

| Input | Used for | Pin |
|---|---|---|
| The Oliver Twins' released Z80 source and data for *Fantasy World Dizzy* (`X-ALL.TXT`, `FRAMES.DAT`, `ROOMDATA.DAT`, `DIZZYFRM.DAT`, `MUSIC128.SPC`, `MUSIC48.SPC`, `PRTDIZZY.PDS`, `info/rooms`, `info/dizzy3_title.png`), as redistributed in `picosonic/D3` | **Every build artifact.** The build chain starts here, not from a tape | `picosonic/D3` commit `4ac31df`; per-file sha256 in `tools/inputs.toml` |
| Tandy CoCo ROMs `BASIC.ROM`, `EXTBASIC.ROM`, `DSKBASIC.ROM` (MAME `coco2b` set) | Running the result in an emulator | sha256 in `NOTES.md` |
| ZX Spectrum 48K ROM (`spectrum.zip`, MAME romset) and a Fantasy World Dizzy `.tzx` dump | **Harnesses only** (original-vs-port comparison); not needed to build | tape sha256 in `NOTES.md` |

The source set is copyrighted by its authors. This repo does not contain it and will not.

## What the repo ships

Port-authored work: all Rust/Python/shell tools, the 6809 code (`target/room36.asm` and the
other hand-written `.asm`), the harnesses, the recipes and the notes. Text that the port
itself wrote (e.g. the quick-save boxes) ships inline. Strings that come from the original
ship only as **keys into your source**, never as text.

## What the bootstrap generates (gitignored, never committed)

| Output | Producer | Inputs |
|---|---|---|
| `extracted/game_text.json` | `textdata PRTDIZZY.PDS X-ALL.TXT` (relative `file` paths) | X-ALL.TXT, PRTDIZZY.PDS |
| `target/text_src/*.asm`, `target/text_src_tape/*.asm` | `textsplit fill` (`target/text_tpl*` templates + `game_text.json`) | game_text.json, the tracked templates |
| `harness/orig_text.lua` | `textsplit export-lua` (bootstrap step `harness_text`): every original string as a Lua table keyed `X-ALL:<line>[#n]`; harness scripts load it via `harness/orig.lua` instead of carrying dialogue as literals | extracted/game_text.json |
| `extracted/rooms.json` | `roomdata --input ROOMDATA.DAT --names info/rooms --verify` | ROOMDATA.DAT, info/rooms |
| `extracted/actors.json` | `actordata --source X-ALL.TXT` | X-ALL.TXT |
| `extracted/frmtable.json`, `dizzy_frames_all.asm` | `spritedata frmtable`, `spritedata dizzy-pack-all` | FRAMES.DAT, DIZZYFRM.DAT |
| `target/dizzy_frames_{bodyA,bodyB,tail}.asm` | `tools/dizzy_split/split.sh` (raw `dizzy_frames_all.asm` + two port-authored comment blocks) | dizzy_frames_all.asm |
| `tools/aycapture/captures/*`, `target/sound_data.asm`, `mix3_stream.asm` | `tools/mksounds.sh` (deterministic Z80 sandbox, no emulator) | MUSIC128.SPC, MUSIC48.SPC |
| `target/room*_data*.asm`, `font_data`, `shared_*`, `frame_table_data*`, `actor_data*` | `tools/regen_art.sh` (roompack) | rooms.json, FRAMES.DAT, actors.json |
| `target/title_*.asm` (except hand-written `title_mix3.asm`) | `tools/stage_pack.sh` (title_image.py, title_holes.py, mktitle) | info/dizzy3_title.png |
| `target/staged_*_lz*.asm`, `staged_syms*`, `image_end_lz*` | `tools/stage_pack.sh` (lzpack) | all of the above |
| DTE-encoded text (`gameplay`, `gap_messages`, `actors`, `ui_room_names`, `msg_data_*`, `dte_table`) | `tools/dte build` | `text_src*` (filled from the templates and your X-ALL.TXT, see below) |
| `target/room36.bin`, `room36_tape.bin`, `room36_floppy.bin`, `room36.cas`, `dizzy.dsk` | `stage_pack.sh`, `tape_pack.sh`, `floppy_pack.sh` | everything above |

Regeneration order: verify inputs -> build the Rust tools -> extract (`roomdata`, `actordata`,
`spritedata`) -> frame split -> `mksounds.sh` -> `regen_art.sh` -> fill text -> harness text -> `dte build`
-> `stage_pack.sh` (tape, floppy variants) -> `tape_pack.sh` / `floppy_pack.sh`.

## The mixed case: text

The port's 6809 text sources are hand-edited code **and** string data. About 97% of the strings
(352 of 361 checked) are the original game's text; about 10 are the port's own (`GAME:OVER`,
`PRESS:SPACE`, `AN:OBJECT`, `EXIT`, the quick-save boxes; the full list is
`tools/textsplit/port_only.txt`). The tracked **templates** `target/text_tpl/` and
`target/text_tpl_tape/` hold the code, comments, port-only strings and `@orig(...)` keys; the
original strings come from `extracted/game_text.json`, which `bootstrap.sh` makes from your
`X-ALL.TXT`/`PRTDIZZY.PDS`. `fill_text` runs `textsplit fill` and writes `target/text_src*`, which
are therefore **generated and gitignored** (the templates are the source). A missing
`game_text.json` is a hard error. The filled output differs from the pre-split legacy files in 24
comment lines only (comments were scrubbed of quoted dialogue); the five artifact hashes are
unchanged. To change text code, edit the template and re-run `bootstrap.sh --steps fill_text,dte,...`.

## Text policy

**Running dialogue and message text from the original is never quoted in a tracked file** (docs,
comments, notes, task text, harness data, test fixtures). **Identifiers may be named**: room titles, item
names and UI labels such as FANTASY WORLD, for identification. Refer to a message by its source line
(`[X-ALL.TXT line 733]`, or the key `X-ALL:733`), never by its words. Which strings are which is decided by
source region in `tools/textsplit/categories.txt` (room table, item table, UI boxes versus
the `PEOPLE TALKING` / `DOING THINGS` / `ALL DEAD` message sections; unknown lines count as messages).
Harness scripts that need the real strings for a pixel or text comparison read them from the generated,
gitignored `harness/orig_text.lua`, never from literals.

Classification finding: `game_text.json` carries no category, only `file`, `line`, `raw`, `decoded`. The
category is derived from the source **region** (`categories.txt`: tag + line range, first match wins,
fail closed). X-ALL.TXT lines 401-503 are room titles, 1081+ item names, the title/credits and the
coin/inventory UI boxes are UI labels, and lines 540-1050 (the three message sections) are messages.

Gates (both run in `scripts/export-public.sh` on the staged tree):

- `textsplit check-public --docs --list FILES` needs your `game_text.json` (`$GPF_GAME_TEXT` or the default
  path) and is **fail-closed when it is present**. It fails on a message string that reads as a quote (an
  upper-case match of >= 3 words or >= 12 characters, or 4+ words in any case) and on a run of >= 3 message
  strings starting within a 6-line window (dialogue split into short rows). Identifiers pass in any number.
  `tools/textsplit/allow.txt` lets ordinary prose through (lower-case only for several words).
- `tools/textsplit/check_docs_nodata.sh` needs **no user data** and always runs: it fails on a run of >= 3
  colon-encoded upper-case segments (the source's own form: colons in place of spaces) unless listed in `nodata_allow.txt`
  (identifiers only). Limitation: it cannot see dialogue written in plain words; that is caught only by the
  user-data gate. When there is no `game_text.json` the export prints `doc-text gate skipped: no user data`.

To fix a finding, run `textsplit scrub --orig-json extracted/game_text.json --list FILES` (dry run; `--apply`
writes) and review `git diff --stat`; it replaces message strings by `[X-ALL.TXT line N]`.

Export gates (`scripts/export-public.sh`): `tools/textsplit/check_templates.sh` (no user data
needed: templates may contain only `@orig` keys and `port_only.txt` strings) and `textsplit
check-public` when the user's `game_text.json` is present.

## Not needed to build (dropped, regenerable only for analysis)

Preview PNGs (`extracted/*_frames`, `art_preview`), the ZX
ground-truth probe dumps under `harness/probes/`, WIP patches, and `baselines/*` logs.
Harness runs that need the original use your own tape and Spectrum ROM under MAME.

## Known gaps (tracked as tasks)

- ~~No script ran the extractors / split the frames~~ -- closed: `tools/bootstrap.sh` (steps `extract`, `split`); `tools/clean_generated.sh` lists/removes the generated set; `docs/BUILD-HASHES.txt` pins the five artifacts.
- `extracted/art_preview`, `room36_cart.rom`, `harness/probes/t0209_solidity.json` have no
  documented producer (none is needed to build).
- ~~Absolute personal paths in extracted JSON~~ -- closed: the extractors now relativize `source_file` and the bootstrap passes relative paths.
- ~~Text built from committed `target/text_src*`; `fill_text` a no-op~~ -- closed: `text_src*` are generated by `textsplit fill`; hand-authored `room36.asm`, `room36_cart.asm`, `title_mix3.asm`, `win_mix3.asm` and the templates are tracked and exported (the export scan allowlists them in `.public-scan-allow`).
