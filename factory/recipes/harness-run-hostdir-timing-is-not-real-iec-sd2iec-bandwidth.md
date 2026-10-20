# harness run --hostdir timing is not real IEC/SD2IEC bandwidth

- **axis:** `storage` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-22

## Decision

T0023 measured 24 jiffies to LOAD a 311-byte conversation block via VICE's -fs8 host-directory device. That device answers KERNAL LOAD through a filesystem trap with +drive8truedrive (true 1541 emulation) OFF, so it does not simulate the IEC serial bus bit rate at all -- the number reflects how fast VICE's trap responds, not how fast a real SD2IEC over JiffyDOS would serve the same file (~2-3 KB/s, per the analytical estimate already in NOTES.md).

## Precondition

Any jiffy/timing measurement taken via harness run --hostdir (not a real .d64/.crt with +drive8truedrive ON) is a mechanism proof, not a bandwidth number. Never quote it as expected real-hardware load time; if real timing is needed, it requires a genuine disk image with true drive emulation on and a JiffyDOS kernal, which nothing in this project has built yet.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
