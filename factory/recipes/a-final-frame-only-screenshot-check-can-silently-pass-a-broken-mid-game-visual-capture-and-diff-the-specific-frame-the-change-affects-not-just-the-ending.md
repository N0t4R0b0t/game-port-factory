# A final-frame-only screenshot check can silently pass a broken mid-game visual -- capture and diff the specific frame the change affects, not just the ending

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-28

## Decision

T0053 wired a custom character-ROM-copy for a door icon into vaultexit2.asm. The inherited single-screenshot check pattern (only the final/ending frame) would have silently passed a completely broken door glyph, because vaultexit.asm/vaultexit2.asm's ending screen is plain text identical whether the door rendered correctly or not -- confirmed directly: a regression that left $D018 pointed at ROM (breaking the door icon) produced a 0.0345% diff on a screenshot of the map/door but a genuine 0.0000% false pass on the end-of-playthrough screenshot alone. Fixed by capturing and diffing TWO screenshots: one of the map with the door visible, one of the completed playthrough -- the door check catches display bugs, the playthrough check catches gameplay-logic regressions, and neither alone covers both failure classes.

## Precondition

Applies to any future check target verifying a change whose effect is visible only in an intermediate frame, not the final one a scripted playthrough ends on. Before trusting a single end-state screenshot as proof a mid-game visual or state change works, check whether that change would still be visible in the final frame; if not, capture and diff the specific frame(s) where the change is actually observable, in addition to (not instead of) the end-state check.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
