# Brickfall C64 (acme, PAL). `make check` is the T0010/T0011 verifier:
# assemble, then `gpfdiff check ..` (../harness.toml): assert the exported labels, run every
# recipe scenario under headless x64sc (each twice: determinism gate), then the built-in
# canary (a mutated golden line MUST be rejected). Exit 0 pass, 1 game FAIL, 2 harness/env
# error (try `gpfdiff doctor --platform c64`).
RECIPE  := ../../../games/brickfall/recipe
GPFDIFF_DIR := ../../../factory/tools/gpfdiff
GPFDIFF := $(GPFDIFF_DIR)/target/release/gpfdiff
SCEN    := $(sort $(notdir $(basename $(wildcard $(RECIPE)/scenarios/*.toml))))
REPEAT  ?= 2
X64SC   ?= x64sc

.PHONY: all check clean shots soundcheck
all: brickfall.prg

brickfall.prg brickfall.vs: brickfall.asm
	acme --vicelabels brickfall.vs -f cbm -o brickfall.prg brickfall.asm

$(GPFDIFF): $(wildcard $(GPFDIFF_DIR)/src/*.rs) $(GPFDIFF_DIR)/Cargo.toml
	cargo build --release --offline --manifest-path $(GPFDIFF_DIR)/Cargo.toml

check: brickfall.prg $(GPFDIFF)
	$(GPFDIFF) check .. --repeat $(REPEAT) --x64sc $(X64SC)

# Reproducible screenshots: real-time x64sc (headless under xvfb), VICE binary-monitor
# display grab at a scenario input point, cropped to the 384x272 PAL visible area,
# integer nearest-neighbour x3 upscale (1152x816), PNG. Needs the gpfdiff binary.
DOCS := ../docs
SHOT = $(GPFDIFF) shot --platform c64 --prg brickfall.prg --labels brickfall.vs --scale 3
shots: brickfall.prg $(GPFDIFF)
	$(SHOT) --scenario ../harness/shot_title.toml --at 100 --out $(DOCS)/screenshot-title-or-over.png
	$(SHOT) --scenario $(RECIPE)/scenarios/full_win.toml --at 1300 --out $(DOCS)/screenshot-play.png
	$(SHOT) --scenario $(RECIPE)/scenarios/game_over.toml --at 690 --out $(DOCS)/screenshot-over.png

# SID trigger verifier: each event (launch, paddle, wall, brick per row, miss, over, win)
# must start its sequence in the sound engine, probed under x64sc. Does not touch the sim.
soundcheck: brickfall.prg $(GPFDIFF)
	../tools/soundcheck.sh $(GPFDIFF) $(RECIPE)

clean:
	rm -rf brickfall.prg brickfall.vs build
