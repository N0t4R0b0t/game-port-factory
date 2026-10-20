# A buffer-persistence proof must confirm which buffer is actually DISPLAYED, not assume it

- **axis:** `raster` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-01

## Decision

Verified a message box's framebuffer bytes were stable for 9 real seconds and treated that as proof it stayed visible -- twice, with the buffer-selection math backwards both times, so the 'proof' was reading the off-screen page the whole time, which of course never changes. The actual bug (redraw() flips to show what it just drew, so a message caller running after it already draws onto the LIVE page, and the old code flipped AWAY from it) was hiding in plain sight under a passing test.

## Precondition

Verifying persistence/visibility of anything in a double-buffered system by reading raw memory rather than an actual rendered frame. Re-derive which physical address is the displayed one from the SAME code path that performs the real flip, every time -- never carry the mapping forward from a previous investigation.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
