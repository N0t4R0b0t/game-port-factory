# Profile a retro game loop by ablation with the frame sync REMOVED, and count passes from a per-pass counter

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-03

## Decision

Two things quietly invalidate this kind of profiling. First, any wait-for-vsync at the end of the frame quantises the result to whole fields, so removing 8% of the work often shows as no change at all, and removing a phase can even appear to make things SLOWER. Every per-phase number must be taken with the sync stripped, then the pacing put back afterwards. Second, timing how far a character walks looks convenient but silently reports walls, steps, knockbacks and deaths as "slow" -- counting a variable the main loop advances exactly once per pass (an animation or RNG counter) is position-independent and immune to all of that. Ablate a phase by replacing its jsr with a nop and rebuilding, and VERIFY the substitution actually matched: a silently-failed text replacement produces a full set of plausible, entirely meaningless numbers, which happened twice here before it was noticed.

## Precondition

Profiling a fixed-loop game on hardware or an emulator with no cycle profiler. Needs a scriptable emulator that can read target RAM (MAME's Lua interface here) and a build cheap enough to ablate repeatedly.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
