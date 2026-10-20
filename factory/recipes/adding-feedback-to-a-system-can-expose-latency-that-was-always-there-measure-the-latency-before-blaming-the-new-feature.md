# Adding feedback to a system can expose latency that was always there -- measure the latency before blaming the new feature

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-11

## Decision

dizzy-coco2's first audio release drew 'sound effects seem delayed'. The sounds were correct; the lag was the mainloop sampling input once per 15Hz pass, which predated audio entirely. A sharp audio transient pins down the moment a game notices a key far more precisely than watching a sprite start to move, so the latency only became perceptible once there was a sound to hear. Measuring keypress-to-state-change directly separated the two in minutes.

## Precondition

A playtest blames a newly added feedback channel (sound, flash, rumble) for lag or delay

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
