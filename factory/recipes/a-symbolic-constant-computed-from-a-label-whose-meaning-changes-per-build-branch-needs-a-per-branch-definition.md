# A symbolic constant computed from a label whose MEANING changes per build branch needs a per-branch definition

- **axis:** `memory_tier` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-11

## Decision

IMAGE_END was defined once, unconditionally, as R9800_DEST+(r9800_staged_end-r9800_staged_start). Under STAGE_LZ those two labels bracket a PACKED BLOB (their difference is the packed length), but under the raw/STAGE_GEN branch they bracket real room content (their difference is the raw length) -- same names, same apparent formula, silently different meaning. The single top-level formula used the packed-branch value in the packed build and IMAGE_END landed INSIDE the still-staged image instead of after it, and a boot-time scratch write clobbered the tail of the image on every boot. The existing R9800_DEST already had a correct per-branch definition (one clause per branch of the if/else); the fix was giving IMAGE_END the same shape rather than trying to make one formula cover both.

## Precondition

Two build variants (packed/raw, debug/release, etc.) share label names across a phase or relocation boundary where the SAME name means a different thing per variant. Never derive a new symbolic constant from such a label with a single unconditional formula -- verify what each branch's labels actually mean before writing the formula, and check the assembled/compiled VALUE (not just that it built) before trusting it.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
