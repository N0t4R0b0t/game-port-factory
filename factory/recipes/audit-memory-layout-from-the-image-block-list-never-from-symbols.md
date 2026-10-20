# Audit memory layout from the image block list, never from symbols

- **axis:** `memory_tier` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-03

## Decision

A symbol is the last LABEL in a file, not the last BYTE. Three separate overruns passed a symbol-based audit on this port -- save-under buffers into room sprites, a room's art 225 bytes into a live framebuffer, and a sprite tail into a table built at boot, which reset the machine. All three are plainly visible in the built image's block list, which is ground truth for what lands where.

## Precondition

The build produces an image format with explicit load addresses (DECB, Intel HEX, cartridge segments)

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
