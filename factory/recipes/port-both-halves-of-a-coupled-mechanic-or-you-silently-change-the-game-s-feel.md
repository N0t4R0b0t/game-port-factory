# Port BOTH halves of a coupled mechanic, or you silently change the game's feel

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-02

## Decision

Original game mechanics are often two cooperating pieces whose constants only make sense together. dizzy-coco2's step-climbing is one: the side-collision probes deliberately test nothing near the feet (so short obstacles are walked INTO, not blocked) and the floor search lifts the character 4px before scanning down (so those obstacles get climbed). Porting the probes without the lift left every step needing a jump AND let the character become permanently embedded inside low geometry -- two apparently unrelated bug reports from one missing half. When you port a collision or physics routine, find what the strange-looking constants are paired with before deciding any of them is arbitrary.

## Precondition

Reimplementing (not recompiling) a game's movement/collision from disassembly. Applies wherever a routine's constants look arbitrary -- that is the signal that a second routine depends on them.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
