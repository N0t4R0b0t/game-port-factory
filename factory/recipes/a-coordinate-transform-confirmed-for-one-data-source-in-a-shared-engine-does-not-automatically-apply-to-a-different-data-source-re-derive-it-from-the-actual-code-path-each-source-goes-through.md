# A coordinate transform confirmed for one data source in a shared engine does not automatically apply to a different data source -- re-derive it from the actual code path each source goes through

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-31

## Decision

Fantasy World Dizzy encodes room-placement scenery x-coordinates in a compact format needing (x-32)*4 to reach real screen pixels (found and fixed early in the port, 'Correction #2'). The live-actor table (movingdata) and its proximity-trigger boxes use raw bytes that LOOK different at the point they're first read (thinglp masks a flag bit; printmoving copies movex directly, no visible math either way) -- so it was easy to assume they were already real pixels and ship actors unscaled. A user's live playtest caught it by pattern-matching the visual symptom (actors suspiciously clustered in the same narrow band Correction #2's bug produced) before any code was re-read. Tracing the ACTUAL shared blit routine both data sources call (not just their entry points) revealed the identical sub-32/shift transform applied at the point x becomes a screen byte offset, confirming both sources need the same fix -- while the player sprite, drawn through a wholly separate routine that never reaches that shared code, correctly needed no transform at all and stayed right the whole time.

## Precondition

A game engine with multiple x/y-bearing data sources (static scenery, live actors/NPCs, trigger/collision boxes, the player) feeding into a SHARED rendering or collision routine downstream, where at least one source's required transform has already been confirmed. Re-derive for each source by tracing forward to where its coordinate is actually consumed, don't infer from a different source having 'felt like the same kind of data.' A visual symptom (values suspiciously clustered in a narrow band relative to screen width) is a strong, cheap signal worth checking even when a plausible non-bug explanation is available.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
