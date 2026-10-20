# When vendored prior-art source includes both the shipped game and its development tools, confirm which routine is the one that actually ships before trusting it

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-29

## Decision

DIZZYFRM.DAT/FRAMES.DAT are read by two different routines in the vendored Fantasy World Dizzy source: EDITOR/PRTMESS.ASM's simplesprite (level-editor tooling, used only by the Oliver Twins' own development tools) and X-ALL.TXT's frame routine (the real assembled game, X-ALL.TXT being the full/complete source listing). They decode the SAME table with DIFFERENT pixel formats (4-bit nibble-packed color vs 1-bit monochrome, no-mask). Reading the editor routine first would have produced a confidently wrong pixel decode that still self-consistency-checked against nothing (never tested), whereas the shipped routine's decode was verified byte-exact against the full FRAMES.DAT blob. Only the file layout (an EDITOR/ subfolder clearly separate from the main assembled listing) tipped this off.

## Precondition

a prior-art source dump includes development/editor tooling alongside the shipped game's own source -- always identify and prefer the routine that is part of the actual assembled/shipped build (look for a full/combined source listing like X-ALL.TXT here) over a superficially similar routine in tooling code, even if the tooling routine is found first or looks cleaner

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
