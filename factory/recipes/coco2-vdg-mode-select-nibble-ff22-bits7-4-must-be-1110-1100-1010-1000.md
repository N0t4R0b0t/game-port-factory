# CoCo2 VDG mode-select nibble ($FF22 bits7-4) must be 1110/1100/1010/1000

- **axis:** `raster` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-29

## Decision

$FF22 bits7-4 select the VDG graphics mode family; CSS is bit3, SEPARATE from that nibble. The only valid nibble values (confirmed against Inman & Inman's 'Assembly Language Graphics for the TRS-80 Color Computer', table 4-2/p.71) end in a 0 bit -- e.g. 1110 for the SAM-mode-6 family (matches SAM V2:V1:V0=110). Writing $F (1111) is not a valid mode at all and produces visibly garbled/incorrect graphics on real emulators (confirmed on both xroar and MAME) even though the SAM address-family bits were otherwise correct -- this was a real, silent bug that survived headless memory-content verification because it doesn't touch RAM at all, only a hardware register with no readback.

## Precondition

Any CoCo1/CoCo2 program setting a PMODE-family (6847 VDG) graphics mode via direct $FF22 register pokes, not BASIC's own PMODE/SCREEN commands.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
