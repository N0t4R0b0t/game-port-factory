# Use STA not LDA for CoCo SAM address-strobe registers under xroar/MAME

- **axis:** `raster` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-29

## Decision

SAM registers ($FFC0-$FFDF) set/clear config bits purely via address decode -- real hardware docs say ANY access (read or write) triggers the strobe. In practice, switching our 9 SAM V/F pokes from LDA to STA was the single change that took the on-screen picture from unrecognizable garbling to a correct, stable image on both xroar and MAME, after every other register-value/order theory had already been ruled out. Cheap and should be the default regardless of whether real hardware truly cares, since it costs nothing and matches what worked.

## Precondition

Any CoCo1/CoCo2 program strobing SAM config registers ($FFC0-$FFDF) under an emulator (xroar and MAME both observed) -- unconfirmed whether real hardware needs this too, but there is no reason not to always use STA.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
