# Reprogramming CIA1 Timer A for cycle-exact measurement breaks the KERNAL jiffy clock

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-22

## Decision

T0030 used CIA1 Timer A as a cycle-accurate stopwatch (the jiffy clock is too coarse to time a single 2KB copy). CIA1 Timer A is the same hardware the KERNAL's default IRQ uses to drive the jiffy clock and keyboard scan -- reprogramming its latch/control registers directly, as this measurement does, leaves the jiffy clock broken for the rest of the program's run. Safe for this task because the routine is short, self-contained, and halts right after printing; would silently break keyboard input and $A2-based timing in anything that keeps running afterward.

## Precondition

Any future code that needs cycle-exact timing AND must keep running normally afterward (not a one-shot diagnostic that halts) should either save/restore CIA1 Timer A's latch and control register state around the measurement, or use CIA #2 ($DD00-$DD0F) instead, which the KERNAL does not use for the jiffy clock. Nothing in this project currently claims CIA #2 for anything else.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
