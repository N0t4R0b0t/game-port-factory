# Brickfall ZX Spectrum 48K (sjasmplus). `make check` is the T0008 verifier:
# assemble, then `gpfdiff check ..` (../harness.toml): assert the exported labels, run every
# recipe scenario under headless MAME (each twice: determinism gate), then the built-in
# canary (a mutated golden line MUST be rejected). Mirrors the C64 one. Exit 0 pass, 1 game
# FAIL, 2 harness/env error (try `gpfdiff doctor --platform zx48`).
#
# MAME needs the `spectrum` romset (spectrum.zip, one file spectrum.rom). It is not
# installed by this repo: supply your own. ZX_ROMPATH is searched in order: $(ZX_ROMPATH) if set,
# then ~/.mame/roms.
RECIPE  := ../../../games/brickfall/recipe
GPFDIFF_DIR := ../../../factory/tools/gpfdiff
GPFDIFF := $(GPFDIFF_DIR)/target/release/gpfdiff
SCEN    := $(sort $(notdir $(basename $(wildcard $(RECIPE)/scenarios/*.toml))))
REPEAT  ?= 2
SJASM   ?= sjasmplus
MAME    ?= mame
ZX_ROMPATH ?= $(firstword $(foreach d,$(HOME)/.mame/roms,$(if $(wildcard $(d)/spectrum.zip),$(d))))
GPFD    = $(GPFDIFF) run --platform zx48 --sna brickfall.sna --labels brickfall.sym --mame $(MAME) --rompath "$(ZX_ROMPATH)"

.PHONY: all check check-blackbox check-scaffold check-render smoke-keys shots clean
all: brickfall.sna

brickfall.sna brickfall.sym: brickfall.asm
	$(SJASM) --nologo --sym=brickfall.sym brickfall.asm

$(GPFDIFF): $(wildcard $(GPFDIFF_DIR)/src/*.rs) $(wildcard $(GPFDIFF_DIR)/lua/*.lua) $(GPFDIFF_DIR)/Cargo.toml
	cargo build --release --offline --manifest-path $(GPFDIFF_DIR)/Cargo.toml

check: brickfall.sna $(GPFDIFF)
	$(GPFDIFF) check .. --repeat $(REPEAT) --mame $(MAME) $(if $(ZX_ROMPATH),--rompath "$(ZX_ROMPATH)")

# The BLACK-BOX workflow on this port as the stand-in for an unknown original (../blackbox/harness.toml: no
# gpf_state, no gpf_input_ret, no symbol file; keys pressed on a frame clock, state read from raw RAM addresses).
#  1. capture all 11 scenarios from the black-box manifest and demand EVERY sample equals the reference
#     model's golden (modulo `#` header lines); capture itself runs each scenario twice (determinism gate),
#     and a second capture (1 run each) must be identical to the first;
#  2. a deliberately wrong ready gate must be exit 2 naming the gate and the last observed value;
#  3. an unknown key name in [input.keys] must be exit 2 listing the valid names;
#  4. `gpfdiff watch` with LEFT held for a second must report the paddle x byte ($F006) moving.
# Exit 0 = all four hold. ~40 s.
BB      := ../blackbox
BBOUT   := build/blackbox
BBEMU    = --mame $(MAME) $(if $(ZX_ROMPATH),--rompath "$(ZX_ROMPATH)")
check-blackbox: brickfall.sna $(GPFDIFF)
	@rm -rf $(BBOUT) $(BBOUT)-2; mkdir -p $(BBOUT) $(BBOUT)-2
	$(GPFDIFF) capture $(BB) --out $(BBOUT) --repeat $(REPEAT) $(BBEMU)
	$(GPFDIFF) capture $(BB) --out $(BBOUT)-2 --repeat 1 $(BBEMU) >/dev/null
	@fail=0; n=0; for s in $(SCEN); do 	  grep -v '^#' $(BBOUT)/$$s.trace > $(BBOUT)/$$s.body; grep -v '^#' $(RECIPE)/golden/$$s.trace > $(BBOUT)/$$s.golden; 	  grep -v '^#' $(BBOUT)-2/$$s.trace > $(BBOUT)-2/$$s.body; 	  if cmp -s $(BBOUT)/$$s.body $(BBOUT)/$$s.golden; then n=$$((n+1)); else echo "FAIL: $$s: black-box capture differs from the golden:"; diff $(BBOUT)/$$s.body $(BBOUT)/$$s.golden | head -5; fail=1; fi; 	  cmp -s $(BBOUT)/$$s.body $(BBOUT)-2/$$s.body || { echo "FAIL: $$s: two captures differ"; fail=1; }; 	done; echo "black-box capture == golden at every sample: $$n/$(words $(SCEN)) scenarios"; test $$fail -eq 0
	@out=$$($(GPFDIFF) check $(BB) --manifest harness.badgate.toml --only launch_left --no-canary $(BBEMU) 2>&1); rc=$$?; echo "$$out" | head -4; 	  test $$rc -eq 2 && echo "$$out" | grep -q 'timed out waiting for the ready gate' && echo "$$out" | grep -q 'last observed value' 	  || { echo "FAIL: a wrong ready gate must be exit 2 naming the gate (got $$rc)"; exit 1; }
	@out=$$($(GPFDIFF) check $(BB) --manifest harness.badkey.toml --only launch_left --no-canary $(BBEMU) 2>&1); rc=$$?; echo "$$out" | head -2; 	  test $$rc -eq 2 && echo "$$out" | grep -q 'unknown key name `CURSORLEFT`' && echo "$$out" | grep -q 'valid names: A-Z' 	  || { echo "FAIL: an unknown key must be exit 2 listing the valid names (got $$rc)"; exit 1; }
	@$(GPFDIFF) watch $(BB) --region 0xF000:0xF0FF --keys "LEFT@0ms+1000ms" --frames 60 $(BBEMU) > $(BBOUT)/watch.txt; rc=$$?; head -8 $(BBOUT)/watch.txt; 	  test $$rc -eq 0 && grep -Eq '0xF006 +70 -> 00' $(BBOUT)/watch.txt 	  || { echo "FAIL: watch with LEFT held must report the paddle x byte 0xF006 moving (rc $$rc)"; exit 1; }
	@echo "CHECK-BLACKBOX PASS"

# `gpfdiff init-oracle` earns its keep: scaffold a black-box oracle for this port (as an unknown original), make only the
# edits a user makes (image, ready gate, the real addresses from brickfall.sym as literals, the 11-column field map),
# then capture == the reference model's golden at every sample, and `check` against the captured traces. ~45 s.
check-scaffold: brickfall.sna $(GPFDIFF)
	GPFDIFF=$(abspath $(GPFDIFF)) MAME=$(MAME) ZX_ROMPATH="$(ZX_ROMPATH)" ./check-scaffold.sh

# read_input against MAME's emulated keyboard matrix (Z X Q A SPACE, Sinclair 2: 6 7 0).
# Not part of `check` (which overwrites A at gpf_input_ret and so never exercises read_input).
smoke-keys: brickfall.sna
	@test -n "$(ZX_ROMPATH)" || { echo "FAIL: no spectrum.zip found for MAME. Supply your own 48K ROM: put spectrum.zip in ~/.mame/roms or set ZX_ROMPATH"; exit 1; }
	@fail=0; for ke in "z :left" "x :right" "q :left" "a :right" "6 :left" "7 :right" "SPACE:fire" "0 :fire"; do \
	  out=$$(SMOKE_KEY="$${ke%%:*}" SMOKE_EXPECT="$${ke##*:}" $(MAME) spectrum -rompath "$(ZX_ROMPATH)" -snapshot brickfall.sna \
	    -autoboot_script keys_smoke.lua -video none -sound none -nothrottle -noreadconfig -skip_gameinfo -seconds_to_run 100 2>&1 | grep '^SMOKE'); \
	  echo "$$out"; echo "$$out" | grep -q '^SMOKE PASS' || fail=1; \
	done; test $$fail -eq 0 && echo "SMOKE-KEYS PASS"

# Render+sound verifier (T0009): cadence (1 sim step per 50 Hz frame while the beeper
# plays), expected sound effects fired, screen pixel-count integrity (no XOR debris).
# Two bot runs: lose all lives (GAME OVER) and clear the board (WIN). ~15 s.
MAMEQ = $(MAME) spectrum -rompath "$(ZX_ROMPATH)" -snapshot brickfall.sna -video none -sound none -nothrottle -noreadconfig -skip_gameinfo -seconds_to_run 3000
check-render: brickfall.sna
	@test -n "$(ZX_ROMPATH)" || { echo "FAIL: no spectrum.zip found for MAME (set ZX_ROMPATH)"; exit 1; }
	@fail=0; for m in over win; do \
	  out=$$(RC_MODE=$$m $(MAMEQ) -autoboot_script render_check.lua 2>&1 | grep '^RCHECK'); \
	  echo "$$out"; echo "$$out" | grep -q '^RCHECK PASS' && ! echo "$$out" | grep -q FAIL || fail=1; \
	done; test $$fail -eq 0 && echo "CHECK-RENDER PASS"

# Screenshots via MAME's own snapshot (native 352x296 incl. border), scaled 3x with
# nearest-neighbour (integer, no smoothing; needs ImageMagick `magick`). Driven by
# shots.lua through the emulated keyboard, so deterministic.
DOCS := ../docs
shots: brickfall.sna
	@test -n "$(ZX_ROMPATH)" || { echo "FAIL: no spectrum.zip found for MAME (set ZX_ROMPATH)"; exit 1; }
	@mkdir -p $(DOCS); for m in play over; do \
	  rm -rf build/snap-$$m; mkdir -p build/snap-$$m; \
	  out=$$(SHOT_MODE=$$m $(MAMEQ) -snapshot_directory build/snap-$$m -autoboot_script shots.lua 2>&1 | grep '^SHOT'); echo "$$out"; \
	  echo "$$out" | grep -q '^SHOT DONE' || { echo "FAIL: shot $$m"; exit 1; }; \
	  dst=$(DOCS)/screenshot-$$m.png; test $$m = over && dst=$(DOCS)/screenshot-over-or-title.png; \
	  magick build/snap-$$m/spectrum/0000.png -strip -filter point -resize 300% $$dst || exit 1; echo "wrote $$dst"; \
	done

clean:
	rm -rf brickfall.sna brickfall.sym build
