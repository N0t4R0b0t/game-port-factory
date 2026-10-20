# Spectrum room-placement colour byte: bit 7 is a horizontal MIRROR flag (frmreverse), not a colour bit

- **axis:** `color` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-03

## Decision

In Fantasy World Dizzy's ROOMDATA format each placement's attribute byte packs colour (%01000111), a 2-bit plot type (bits 3-4) AND bit 7 = frmreverse, which the sprite blitter consumes by walking the bitmap right-to-left (X-ALL.TXT thinglp ~5553, frame ~4072/4103). Ignoring it silently draws every mirrored placement unflipped -- which does not look like a missing feature, it looks like FOUR unrelated art bugs (railings facing the wrong way, a 'wrong' painting, a sword with its tip 'split off and drawn further left', a 'missing' balustrade). It also rides through the format's same_colour_as_previous runs, so it must be carried forward with the rest of the attribute, not read per-placement. Cost is one extra sprite variant per mirrored frame; key the dedup cache on frame+mirrored, not frame alone.

## Precondition

Any port of a Codemasters/Oliver-twins-era Spectrum game whose room data stores per-placement attribute bytes; check the room-draw loop for a reverse/flip bit before assuming an attribute byte is colour-only. Verify by rendering a room known to be symmetric -- an unflipped mirror reads as broken art, not as a missing flag.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
