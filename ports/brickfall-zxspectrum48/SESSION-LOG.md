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
- 2026-10-17 — handoff: Blocked on brickfall-c64 T0010/T0011 (copy the 8.8 fixed-point step logic to Z80 and reuse the same harness). sjasmplus is in ~/.local/bin.
- 2026-10-17 — handoff: Unblocked: harness exists (factory/tools/gpfdiff, Target trait; c64.rs is the reference backend). Do the Z80 sim to match games/brickfall/recipe README + golden traces, then add a mame.rs backend. MAME is installed; locate the ZX Spectrum ROM first (dizzy-coco2 harness/zx_film.lua and tools/zx_orig.sh show how MAME was driven there).
- 2026-10-17 — T0008 -> doing (ZX48 build: sjasmplus, same gpf_state contract; diff via MAME poll of RAM)
- 2026-10-17 — T0008 -> done (ZX48 build: sjasmplus, same gpf_state contract; diff via MAME poll of RAM)
- 2026-10-17 — handoff: T0008 done+reviewed: Z80 build + MAME backend; both platforms pass all 11 scenarios bit-exact vs the Rust model. NEXT: art/sound polish per target (C64: sprites/colours/SID; ZX: UDG art, beeper) with a local-vision readability check; README section + screenshots for brickfall; decide whether to attach built .prg/.sna as a release (original game, so no IP issue). Needs user's own spectrum.zip in ~/.mame/roms or ZX_ROMPATH.
- 2026-10-17 — T0009 -> doing (ZX48 art+sound polish)
- 2026-10-17 — T0009 -> done (ZX48 art+sound polish)
- 2026-10-17 — handoff: Complete; see brickfall-c64 handoff. check + check-render pass; needs user's spectrum.zip.
