# Verify memory-relocation changes by full address-range audit, not 'highest symbol below the boundary'

- **axis:** `memory_tier` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-02

## Decision

A headroom check that only asks 'what is the highest symbol address below the boundary' is blind to a real failure mode: content defined LATER in file/assembly order can independently land ABOVE the boundary while something earlier still sits safely under it (dizzy_frames_all.asm's later frames, in this case). This let a live corruption bug (24 symbols overlapping a live framebuffer) ship and stay shipped across multiple sessions undetected, because assembly succeeding and playtest trajectories matching are ALSO insufficient -- both passed on the broken build, since the corrupted addresses happened to not be exercised by the specific test in use. The correct check: for every protected region (framebuffers, ROM), confirm NO symbol's address falls inside it except the intended boundary markers themselves.

## Precondition

Any 8-bit target build that relocates code/data across multiple memory regions with hard boundaries (framebuffers, ROM, reserved system RAM) and has no assembler-level protection against silently overlapping them.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
