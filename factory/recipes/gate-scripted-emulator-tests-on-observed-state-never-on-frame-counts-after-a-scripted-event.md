# Gate scripted-emulator tests on OBSERVED state, never on frame counts after a scripted event

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-12

## Decision

dizzy-coco2's harnesses used a respawn poke to teleport Dizzy and then pressed keys at fixed frame offsets. When the respawn path grew ~100 frames of blocking audio, six separate results broke in one session -- false FAILs (keys pressed while the game was frozen in a tune) and one false PASS (a state poke undone by the room load, leaving a different obstacle to do the blocking) -- and not one was a game regression. Waiting for arrival, then for the CPU to leave the blocking routine (PC range, or a return address on the stack for loops that live in wait_vsync), made all of them indifferent to how long any sound takes. When a test fails after an unrelated change, sweep its input timing or instrument one run before believing the game broke.

## Precondition

A scripted emulator test that drives input after a game event whose duration can change (respawns, transitions, messages, audio)

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
