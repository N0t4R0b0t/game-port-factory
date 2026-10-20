# Measure emulated-time performance with an emulator's own deterministic run-length flag, never wall-clock under a free-running/turbo mode

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-31

## Decision

Three rounds of 'it's still slow' on dizzy-coco2 were answered with guesses about what was expensive, because the obvious measurement was unusable: xroar's gdb stub only responds when the emulator runs with -no-ratelimit, and in that mode it runs as fast as the host allows, so mainloop-passes-per-host-second varied 2.5x between identical runs of the same binary -- pure host CPU noise, no signal. Switching to MAME's -seconds_to_run N, which counts EMULATED seconds by construction, gave stable repeatable numbers immediately: instrument a counter, sample at two different emulated durations, take the delta to cancel boot/load time. That turned 'it feels slow' into '9.8 updates/sec versus the original's 16.7' and, with subsystems selectively disabled, attributed 41% of the entire frame budget to one specific subsystem (redrawing 6 small animated sprites every pass when their animation only advanced every 4th pass).

## Precondition

Profiling a retro/emulated target where the emulator offers a deterministic emulated-duration run mode (MAME's -seconds_to_run, or equivalent). Requires being able to read a counter out of guest memory at exit or periodically. If the only available measurement is wall-clock under a turbo/unthrottled mode, treat the numbers as unusable for attribution rather than as weak evidence -- the host-noise floor can exceed the effect being measured.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
