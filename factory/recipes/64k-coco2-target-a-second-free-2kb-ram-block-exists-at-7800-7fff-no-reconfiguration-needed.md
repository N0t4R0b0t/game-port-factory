# 64K CoCo2 target: a second free 2KB RAM block exists at $7800-$7FFF, no reconfiguration needed

- **axis:** `memory_tier` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-02

## Decision

Framebuffer B ends at $77FF and ROM doesn't start until $8000 on either a 32K or 64K CoCo2 -- this 2KB is ordinary, always-mapped RAM on the base address range every CoCo2 has, ident cal to the already-used $5800-$5FFF inter-framebuffer gap, just not discovered/used until this session. Confirmed safe by checking the runtime stack pointer (~$03D3, nowhere near it) before relying on it. The FULL 64K ceiling (comparable to the original Spectrum's usable budget) is bigger still -- $8000-$FEFF via the SAM's all-RAM/banking mode -- but that is a real architecture change (the CPU can't fetch further instructions from ROM once banked out) needing its own dedicated session, not a quick add.

## Precondition

Target is a CoCo1/CoCo2-family machine (SAM-based memory map) using PMODE4 double-buffering at $4000/$6000 with a program loaded below $4000. The exact free block shifts if the framebuffer base or program load address differs.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
