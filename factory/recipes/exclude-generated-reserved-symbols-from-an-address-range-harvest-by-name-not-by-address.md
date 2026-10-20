# Exclude generated/reserved symbols from an address-range harvest by NAME, not by address

- **axis:** `memory_tier` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-11

## Decision

stage_pack.sh's symbol harvest scooped up anything in [0x8000, dest_end) from a raw-pass map, assuming that range only ever contained staged room-data labels. Once the raw image grew past 8KB, block-boundary labels' own real (unphased) addresses and a title-chunk scratch address both coincidentally fell inside that range and got re-harvested as if they were room data, causing 'Multiply defined symbol' against the labels room36.asm already owns. Excluding by name fixed it permanently; excluding by address range would only have patched today's coincidence.

## Precondition

Any tool that classifies symbols/objects by which numeric range they fall in, when that range's population is expected to grow. A coincidence that doesn't happen at today's sizes will happen at tomorrow's.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
