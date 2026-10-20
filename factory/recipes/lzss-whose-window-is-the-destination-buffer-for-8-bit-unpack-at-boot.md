# LZSS whose window is the destination buffer, for 8-bit unpack-at-boot

- **axis:** `memory_tier` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-06

## Decision

Using the output buffer itself as the match window removes the usual 4KB of ring-buffer decode RAM entirely, which on a 64K machine with a 12KB staging cap matters far more than the last few percent of ratio. On 6809 the decoder is ~60 bytes: coma/comb on dist-1 gives -dist so leax d,y gets the copy source in one instruction.

## Precondition

Data is unpacked once, at boot, into one contiguous destination that is never read before it is written. Overlapping copies must run forwards a byte at a time -- dist=1 is how runs are encoded.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
