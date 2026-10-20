# Session log — Brickfall

Append-only. One line per session, newest at the bottom.

- 2026-10-20 — port initialised
- 2026-10-20 — strategy -> reimplement (original design: no source binary to excavate); stage -> scaffold
- 2026-10-20 — T0001 edited: title 'Write platform-neutral recipe: games/<game>/recipe/README.md (rules, state contract, input contract, acceptance)' -> 'Recipe: games/brickfall/recipe/README.md (shared, already written for the c64 port; nothing to do for coco2)'; verify '' -> 'test -f games/brickfall/recipe/README.md'
- 2026-10-20 — T0002 edited: title 'Reference model as oracle: implement the recipe rules in Rust, emit golden traces' -> 'Reference model + golden traces: games/brickfall/recipe/{model,golden} (shared; consumed as is)'; verify '' -> 'ls games/brickfall/recipe/golden/*.trace | wc -l | grep -qx 11'
- 2026-10-20 — T0003 edited: verify '' -> 'gpfdiff/../factory/tools/gpfdiff/target/release/gpfdiff doctor --platform coco2'
- 2026-10-20 — T0004 edited: title 'Stand up differential harness: scripted input, state capture, diff against reference-model traces' -> 'gpfdiff coco2 backend (MAME coco2b, DECB loader in Lua, A register injection) + doctor/manifest/README'; verify '' -> 'cargo test --offline --manifest-path factory/tools/gpfdiff/Cargo.toml'
- 2026-10-20 — T0005 edited: title 'Vertical slice on target: smallest playable thing, passing the harness' -> '6809 build, PMODE4 minimal art, 60->50 Hz accumulator; bit-exact vs golden traces'; verify '' -> 'make -C ports/brickfall-coco2/target check'
- 2026-10-20 — T0006 edited: title 'Art and sound polish within the asset budget' -> 'Art and sound polish (row colours via artifact, text, DAC sound); sim untouched'; verify '' -> 'make -C ports/brickfall-coco2/target check && make -C ports/brickfall-coco2/target smoke-keys'
- 2026-10-20 — T0003 edited: verify 'gpfdiff/../factory/tools/gpfdiff/target/release/gpfdiff doctor --platform coco2' -> 'factory/tools/gpfdiff/target/release/gpfdiff doctor --platform coco2'
- 2026-10-20 — T0001 -> doing (Recipe: games/brickfall/recipe/README.md (shared, already written for the c64 port; nothing to do for coco2))
- 2026-10-20 — T0001 -> done (Recipe: games/brickfall/recipe/README.md (shared, already written for the c64 port; nothing to do for coco2))
- 2026-10-20 — T0002 -> doing (Reference model + golden traces: games/brickfall/recipe/{model,golden} (shared; consumed as is))
- 2026-10-20 — T0002 -> done (Reference model + golden traces: games/brickfall/recipe/{model,golden} (shared; consumed as is))
- 2026-10-20 — T0003 -> doing (Stand up target toolchain + emulator; build and run a hello-world on target)
- 2026-10-20 — T0003 -> done (Stand up target toolchain + emulator; build and run a hello-world on target)
- 2026-10-20 — T0004 -> doing (gpfdiff coco2 backend (MAME coco2b, DECB loader in Lua, A register injection) + doctor/manifest/README)
- 2026-10-20 — T0004 -> done (gpfdiff coco2 backend (MAME coco2b, DECB loader in Lua, A register injection) + doctor/manifest/README)
- 2026-10-20 — T0005 -> doing (6809 build, PMODE4 minimal art, 60->50 Hz accumulator; bit-exact vs golden traces)
- 2026-10-20 — T0005 -> done (6809 build, PMODE4 minimal art, 60->50 Hz accumulator; bit-exact vs golden traces)
- 2026-10-20 — handoff: coco2 port + gpfdiff coco2 backend verified (check 11/11 x2, smoke-keys, 84 cargo tests, zx48+c64 no regression). Next: T0006 art/sound polish (row colours via artifact, text, DAC sound) with sim untouched; joystick input is a design call; real-hardware/XRoar check not done.
