# Session log — Brickfall

Append-only. One line per session, newest at the bottom.

- 2026-10-17 — port initialised
- 2026-10-17 — strategy -> reimplement
- 2026-10-17 — T0001 -> done (Inventory and hash source files; record exact versions/regions in NOTES.md)
- 2026-10-17 — T0002 -> done (Fingerprint the engine and toolchain the original was built with)
- 2026-10-17 — T0003 -> done (PRIOR ART SWEEP: existing disassemblies, decomps, source releases, ports, format docs)
- 2026-10-17 — T0004 -> done (Answer: does source exist? is target >= source in capability?)
- 2026-10-17 — T0005 -> done (Commit to a strategy (source-port | recompile | reimplement) and record why)
- 2026-10-17 — Stages 1-3 closed as N/A: Brickfall is an original design; games/brickfall/recipe/README.md is the source of truth, strategy=reimplement by construction. Oracle = Rust reference model, not an original binary.
- 2026-10-17 — stage -> scaffold
- 2026-10-17 — T0009 -> doing (Reference model: Rust oracle implementing games/brickfall/recipe/README.md, emits golden traces for scenarios/*.toml)
- 2026-10-17 — T0009 -> done (Reference model: Rust oracle implementing games/brickfall/recipe/README.md, emits golden traces for scenarios/*.toml)
- 2026-10-17 — handoff: T0009 reference model done+verified (9 tests, golden traces reproduce). NEXT: T0010 C64 build (acme; export gpf_state/gpf_bricks labels and a symbol file; simulation must match games/brickfall/recipe/README.md 'Resolved ambiguities' exactly) and T0011 generic harness polling gpf_state in headless x64sc vs golden/*.trace. Run both as gpf-builder jobs; verify with factory/tools/gpfdiff. Then T0008 on the zx port (sjasmplus at ~/.local/bin, MAME). Promote harness to factory/tools/ when ZX is the second caller. Nothing pushed anywhere; public repo is local only.
- 2026-10-17 — T0010 -> doing (C64 build: acme, exports gpf_state/gpf_bricks via symbol file)
- 2026-10-17 — T0011 -> doing (Generic harness: poll gpf_state under headless VICE, diff vs golden trace (promote to factory/tools/ on 2nd caller))
- 2026-10-17 — T0010 -> done (C64 build: acme, exports gpf_state/gpf_bricks via symbol file)
- 2026-10-17 — T0011 -> done (Generic harness: poll gpf_state under headless VICE, diff vs golden trace (promote to factory/tools/ on 2nd caller))
- 2026-10-17 — handoff: T0009-T0011 done and reviewed. C64 build + gpfdiff harness pass. NEXT: ZX48 port (brickfall-zxspectrum48 T0008): Z80 build with sjasmplus (~/.local/bin) exporting gpf_state/gpf_bricks/gpf_input_ret under the same recipe, plus a MAME backend implementing the Target trait in factory/tools/gpfdiff/src/target.rs (see c64.rs for the shape). Then art/sound polish per target and a screenshot-readability check (local vision model). Joystick input is manual-test only.
- 2026-10-17 — T0013 -> doing (C64 art+sound polish)
- 2026-10-17 — T0013 -> done (C64 art+sound polish)
- 2026-10-17 — handoff: Brickfall complete for both targets: sim bit-exact vs model, art+sound polished, screenshots, release script (scripts/release-brickfall.sh -> dist/, gitignored). Sound never heard by a human; C64 joystick manual-only. NEXT: user decisions -- publish repo to GitHub, attach dist/* as a release, email Oliver Twins re Dizzy. Optional: chain soundcheck/check-render into check; Rust PNG scaler to drop ImageMagick dependency.
- 2026-10-20 — T0008 edited: verify 'gpf init --help | grep -qi original' -> 'gpf init --help | grep -q original'
- 2026-10-20 — T0008 -> done (Factory friction: gpf init seeds 'original source' tasks; add an original-game mode (recipe is the source of truth, stages 1-3 collapse))
- 2026-10-20 — T0012 -> done (Factory friction: gpf task has no command to edit verify/tier on an existing task)
