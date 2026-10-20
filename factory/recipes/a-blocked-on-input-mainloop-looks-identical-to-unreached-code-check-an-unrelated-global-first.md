# A blocked-on-input mainloop looks identical to unreached code -- check an unrelated global first

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-02

## Decision

When a game's mainloop can block synchronously waiting for player input (a modal message box, a dialog), a poke-based test that never supplies that input freezes the WHOLE game, not just the feature under test. From outside, that is indistinguishable from the new code path simply never executing -- both show the target state frozen. Spent real debugging time double-checking assembled branch bytes and adding an execution counter before realizing the counter itself read zero because the mainloop hadn't run at all since the message box appeared. The fast, correct check: read back an unrelated global that should be advancing regardless (an RNG counter, a frame counter) BEFORE concluding new code is unreached -- if that's also frozen, the bug is upstream (a blocking wait), not in the code being tested.

## Precondition

Testing via direct memory pokes against an emulator, on any game/program whose main loop can synchronously block on player input (message boxes, dialogs, prompts). Not needed when driving through real input events, since a blocked wait is then visibly 'nothing happens on keypress' rather than silently misattributed.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
