# Brickfall Tandy CoCo 2 (lwasm). `make check` is the port's verifier:
# assemble, then `gpfdiff check ..` (../harness.toml): assert the exported labels, run every
# recipe scenario under headless MAME `coco2b` (each twice: determinism gate), then the
# built-in canary (a mutated golden line MUST be rejected). Mirrors the C64 and ZX ones.
# Exit 0 pass, 1 game FAIL, 2 harness/env error (try `gpfdiff doctor --platform coco2`).
#
# MAME needs the `coco2b` romset (bas13.rom + extbas11.rom). It is not installed by this
# repo: supply your own. COCO_ROMPATH is searched first (if set), then ~/.mame/roms.
GPFDIFF_DIR := ../../../factory/tools/gpfdiff
GPFDIFF := $(GPFDIFF_DIR)/target/release/gpfdiff
REPEAT  ?= 2
LWASM   ?= lwasm
MAME    ?= mame
COCO_ROMPATH ?= $(firstword $(foreach d,$(HOME)/.mame/roms,$(if $(wildcard $(d)/coco2b $(d)/coco2b.zip),$(d))))

.PHONY: all check check-live check-live-blackbox smoke-keys clean
all: brickfall.bin

# --map lists every symbol, the harness reads gpf_state/gpf_bricks/gpf_input_ret from it
brickfall.bin brickfall.map: brickfall.asm
	$(LWASM) --format=decb --output=brickfall.bin --map=brickfall.map --list=brickfall.lst brickfall.asm

$(GPFDIFF): $(wildcard $(GPFDIFF_DIR)/src/*.rs) $(wildcard $(GPFDIFF_DIR)/lua/*.lua) $(GPFDIFF_DIR)/Cargo.toml
	cargo build --release --offline --manifest-path $(GPFDIFF_DIR)/Cargo.toml

check: brickfall.bin $(GPFDIFF)
	$(GPFDIFF) check .. --repeat $(REPEAT) --mame $(MAME) $(if $(COCO_ROMPATH),--rompath "$(COCO_ROMPATH)")

# Cross-port check: diff this port against the LIVE Spectrum port (harness.live.toml, [oracle] source = "live").
# Needs the Spectrum ROM too (ZX_ROMPATH or ~/.mame/roms) and the Spectrum port built (make -C ../../brickfall-zxspectrum48/target all).
check-live: brickfall.bin $(GPFDIFF)
	$(GPFDIFF) check .. --manifest harness.live.toml --repeat $(REPEAT) --mame $(MAME) $(if $(COCO_ROMPATH),--rompath "$(COCO_ROMPATH)")

# The full original-as-oracle workflow: this port against the Spectrum Brickfall treated as an UNKNOWN ORIGINAL (its
# black-box manifest: no gpf_state, keys on a 50 Hz frame clock, raw RAM addresses; harness.live-blackbox.toml).
# Needs the Spectrum ROM too and the Spectrum port built (make -C ../../brickfall-zxspectrum48/target all).
check-live-blackbox: brickfall.bin $(GPFDIFF)
	$(GPFDIFF) check .. --manifest harness.live-blackbox.toml --repeat $(REPEAT) --mame $(MAME) $(if $(COCO_ROMPATH),--rompath "$(COCO_ROMPATH)")

# read_input against MAME's emulated keyboard matrix (Z X LEFT RIGHT SPACE).
# Not part of `check` (which overwrites A at gpf_input_ret and so never exercises read_input).
# Needs the coco2b ROMs (COCO_ROMPATH or ~/.mame/roms). ~10 s.
STATE_ADDR = $(shell awk '$$1=="Symbol:" && $$2=="gpf_state" {print $$NF}' brickfall.map)
MAMEQ = $(MAME) coco2b $(if $(COCO_ROMPATH),-rompath "$(COCO_ROMPATH)") -ext "" -video none -sound none -nothrottle -noreadconfig -skip_gameinfo -seconds_to_run 100
smoke-keys: brickfall.bin
	@fail=0; for ke in "z:left" "x:right" "LEFT:left" "RIGHT:right" "SPACE:fire"; do \
	  out=$$(SMOKE_BIN=brickfall.bin SMOKE_STATE=$(STATE_ADDR) SMOKE_KEY="$${ke%%:*}" SMOKE_EXPECT="$${ke##*:}" $(MAMEQ) -autoboot_script keys_smoke.lua 2>&1 | grep '^SMOKE'); \
	  echo "$$out"; echo "$$out" | grep -q '^SMOKE PASS' || fail=1; \
	done; test $$fail -eq 0 && echo "SMOKE-KEYS PASS"

clean:
	rm -f brickfall.bin brickfall.map brickfall.lst
