# When a live gdb-poke test result contradicts what the code should do, verify with a compiled-in boot-time test before trusting the live result

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-31

## Decision

Fixed a gdb-remote stub halting the target on connect earlier this port (continue + interrupt-before-access pattern, see the prior recipe on this). That fix is necessary but not always sufficient: two real bug fixes (buffer-invalidation on item pickup, on message display) both appeared to FAIL when verified by holding position via many rapid run_for()/halt/resume cycles in a tight loop -- the visual result never matched what the code should produce. Building a second, independent verification path -- compiling the exact same state change directly into the boot sequence, with zero live debugger interaction after launch -- showed BOTH fixes actually work correctly. The likely cause: code that polls a real hardware timer (vsync wait via a PIA status bit) can have its apparent timing perturbed by very frequent CPU halt/resume cycling, even though the continue/interrupt pattern is itself correct. A live-poke test result that contradicts a straightforward reading of the code is therefore not proof of a bug -- it may be the test harness itself interfering with timer-dependent code paths.

## Precondition

The code under live verification polls a real (or emulated) hardware timer/interrupt flag as part of its normal operation (vsync waits, frame-rate pacing, periodic hardware polling) AND the verification technique halts/resumes the CPU many times in quick succession (a tight poke-and-hold loop). Not relevant for simple state reads/writes that don't depend on elapsed real time.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
