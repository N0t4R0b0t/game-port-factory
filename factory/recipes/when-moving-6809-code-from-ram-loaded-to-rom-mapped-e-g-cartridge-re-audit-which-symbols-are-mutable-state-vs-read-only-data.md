# When moving 6809 code from RAM-loaded to ROM-mapped (e.g. cartridge), re-audit which symbols are mutable state vs read-only data

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-29

## Decision

Rebuilt a working DECB-loaded (RAM-resident) CoCo2 program as a cartridge (org $c000, raw binary) by just changing the org address, reusing the same variable declarations (fcb 0/fdb 0 for dizzy_x, blit_ptr, etc) unchanged. Since the whole program including 'variables' now lived in ROM space, every write to them silently did nothing (writes to ROM are no-ops), producing a distinctive and easy-to-misdiagnose symptom: the program visibly starts running (hardware register pokes still work, those aren't RAM) but state that should update doesn't, giving a 'runs partway then falls apart into visual garbage' result that looks like a timing or corruption bug, not a memory-model bug. Also needed an explicit stack pointer (lds) since a ROM-mapped/cart-booted program doesn't inherit one the way a program loaded into an already-running BASIC session does.

## Precondition

moving 6809 (or similar) code from a RAM-loaded/BASIC-hosted execution context to a ROM-mapped one (cartridge, EPROM, etc), or vice versa -- explicitly separate mutable state (must get its own RAM org, using rmb not fcb/fdb so no dead bytes get baked into the ROM image) from code and read-only reference data (fine to stay wherever org points), and explicitly set up a stack pointer if the new context doesn't guarantee one already exists

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
