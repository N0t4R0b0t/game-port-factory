# Move verbose prose out of RAM into a numbered paragraph book

- **axis:** `memory_tier` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-12

## Decision

Wasteland (1988, C64) shipped a printed book of numbered text paragraphs; encounters referenced a paragraph number and the prose lived on paper. Do not compress a text-heavy game's prose to fit — relocate it. Modern equivalents: companion PDF, text-only disk side, paged overlay.

## Precondition

Target `memory_tier` is `small` or `tiny`, AND the source game is text-heavy, AND **the
target's storage cannot hold the text either**.

That third clause was added after the first real check (fallout1-c64, 2026-08-12). The
technique addresses *storage and address-space* scarcity, not RAM scarcity — banked
cartridge ROM or multi-disk relieves it directly, because prose is read-only data and
read-only data can live in banked ROM and be read in place without consuming RAM.

So: on a bare C64 with limited disk sides, this recipe applies. On a C64 with a banked
cartridge (EasyFlash-class, ~1 MB) it becomes **optional** — a stylistic homage rather than
a necessity. Check which situation you are in before reaching for it.

## Outcome

_Fill in after the port ships: did this hold up?_
