# Double-buffer CoCo2 graphics via SAM F-bit page flip, not single-buffer clear+redraw

- **axis:** `raster` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-29

## Decision

CoCo2 has 64K RAM -- room for two 6K PMODE4 framebuffers (e.g. $4000 and $6000) simultaneously. SAM's F-register display-start-address bits can point the VDG at either one, and switching which is displayed is a single register strobe (Inman & Inman appendix E 'screen offsets' gives the exact addresses for arbitrary offsets). Always drawing into the currently off-screen buffer and flipping only once a frame is complete eliminates all mid-draw visible flicker -- a single-buffer clear+redraw-every-frame approach is visibly flickery at real 6809/SAM speed even though it looks fine in an instant headless memory snapshot.

## Precondition

Any CoCo1/CoCo2 target with enough free RAM for two full framebuffers of the graphics mode in use (PMODE4's 6K x2 = 12K comfortably fits in 64K alongside code/data); lower-RAM CoCo1 configs (4K/16K) may not have room.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
