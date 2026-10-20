# CoCo2: SAM all-RAM mode ($FFDF) unlocks ~32KB at $8000-$FEFF; stage low, PHASE/DEPHASE + copy loop to relocate

- **axis:** `memory_tier` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-02

## Decision

CoCo2 default ships with $8000+ mapped to BASIC ROM (32K usable of the physical 64K). sta $ffdf sets the SAM's TY bit and makes $8000-$FEFF genuine writable RAM without disturbing $0000-$7FFF or the SAM/PIA's own live registers (verified in MAME: round-trip write/readback, vsync flag keeps changing over real time, switch-back via $ffde correctly restores ROM). BUT BASIC's own CLOADM loader runs entirely before user code, still in ROM mode -- a DECB block aimed directly at $8000+ silently fails to load. Fix: stage the data at an ordinary low CLOADM destination (well below wherever your own code's org starts, clear of the stack), wrap it in lwasm's PHASE <target>/DEPHASE so labels resolve to their real $8000+ address while the physical bytes land in the staging spot, then copy staged bytes up to $8000+ in your own boot code immediately after engaging all-RAM mode, before anything else touches memory.

## Precondition

Real 64K CoCo2 hardware (not a base 32K unit) or an emulator configured as 64K; target boots via BASIC CLOADM/LOADM (cassette or disk), not a cartridge ROM; assembler supports PHASE/DEPHASE (lwasm does) or equivalent pseudo-org; manufacturer docs warn TY 'should be cleared at all times' -- functionally verified safe in MAME emulation only, NOT yet confirmed on real hardware.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
