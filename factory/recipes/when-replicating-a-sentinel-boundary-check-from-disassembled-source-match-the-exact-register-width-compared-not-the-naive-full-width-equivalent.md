# When replicating a sentinel/boundary check from disassembled source, match the exact register width compared, not the naive full-width equivalent

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-29

## Decision

FRAMES.DAT's object-sprite table uses 0xFFxx as a 'no sprite' sentinel, but the original Z80 only checks the HIGH byte (`ld a,d / cp 255`), not the full 16-bit offset against 0xFFFF. A first-pass converter that checked the full u16 against 0xFFFF produced 35 false 'out of bounds' errors on values like 0xFF8B, which looked exactly like corrupted/misparsed data rather than a converter bug -- costly to debug blind. Confirmed correct after re-reading the actual comparison instruction in source and matching its register width exactly; entry counts became exact (196 real + 60 sentinel = 256) with zero warnings.

## Precondition

extracting a table/array format from disassembled or original assembly source that uses a sentinel value to mark empty/missing slots -- always check what register width (8-bit vs 16-bit) and what comparison the source instructions actually use before assuming the obvious full-width equivalent

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
