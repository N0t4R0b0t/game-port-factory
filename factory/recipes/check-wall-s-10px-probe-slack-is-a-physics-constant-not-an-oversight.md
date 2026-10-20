# check_wall's 10px probe slack is a physics constant, not an oversight

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-06

## Decision

Probing only dizzy_y-10/-14/-18 leaves a 10px window in which Dizzy may move sideways with his feet level with a platform side. That window is what lets a step-climb happen in mid-air, and 8px-riser staircases are climbed through it. Adding a foot probe closed it and made room 35's staircase stop at its third step.

## Precondition

Porting a platformer whose original probes the upper body only. Verify against a real staircase before 'fixing' the probe set.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
