# Pad with fill (NOP), never rmb, where the instruction stream flows through it

- **axis:** `storage` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-20

## Decision

rmb reserves space without emitting bytes, so a segmented load file SPLITS at the pad and the loader never writes those bytes -- execution then runs whatever RAM held. Emulators that clear RAM benignly (MAME coco2b) hide this indefinitely while a real load path (xroar coco2bus) fails: in dizzy-coco2 the garbage cleared PIA0 CRA's DDR-select bit, every key scanned as held, and the title screen froze with no music while 20+ harnesses stayed green. Break-proof by enumerating every load-file gap at build time and failing on any gap that is not a known data buffer (tools/memaudit.py).

## Precondition

Target loads via a segmented load file (DECB/CLOADM and equivalents) in which a gap between segments leaves those addresses untouched by the loader

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
