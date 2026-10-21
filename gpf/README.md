# gpf

On-disk state machine for resumable porting projects. Build: `cargo build --release --offline --manifest-path gpf/Cargo.toml`.
Run `gpf --help` and `gpf <cmd> --help` for everything; this lists what is easy to miss.

## init

`gpf init <slug> --title T --target P [--source P] [--game G] [--original] [--public]`

- Normal (existing game with a binary): seeds identify, classify, toolchain, then the **oracle chain**
  (find state addresses with `gpfdiff watch`; field map + ready gate in `harness.toml`; golden traces with
  `gpfdiff capture`; `expectations.toml`; `gpfdiff check`). See `factory/tools/gpfdiff/README.md`.
- `--original`: no binary to excavate; recipe, reference model, toolchain, harness, slice. If
  `games/<game>/recipe/README.md` already exists and is no longer the generated stub (a second port of the
  game), the recipe and reference-model tasks are pre-closed and `next_action` names the first real task.
- `--public`: also seeds the public-release chain modelled on `ports/dizzy-coco2` (provenance audit, inputs
  manifest, bootstrap, hash list, export gates, clean-clone proof). With `--original` only the subset that
  applies is seeded: no user-supplied media, so no inputs manifest and no original-text gate.
- Directories: only what the mode uses, since git drops empty ones. `harness/` and `target/` always (with a
  `.gitkeep`); normal mode also `source/`, `extracted/` (gitignored) and `research/` (`.gitkeep`).

## tasks

- `gpf task edit <slug> <id> --note TEXT` APPENDS to the note (joined with ` | `); it never replaces.
  `block` and `escalate` still set the note.
- `gpf task done <slug> <id> --run-verify` runs the task's verify string with `sh -c` from the repo root.
  Nonzero exit: prints the last 20 lines, exits 1, task stays as it was. The result (pass or fail) goes to
  SESSION-LOG.md. A task with no verify string is an error. Without the flag `done` is unchanged.
