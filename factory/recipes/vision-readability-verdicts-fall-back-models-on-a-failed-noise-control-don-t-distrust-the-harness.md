# Vision readability verdicts: fall back models on a failed noise control, don't distrust the harness

- **axis:** `color` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-22

## Decision

qwen2.5vl:7b passed forced-choice on 2026-08-12's test pair but failed its own noise control on a fresh 12x21 humanoid/noise pair (called black/white structured noise 'a human figure' in both option orders); minicpm-v passed cleanly on the same images. The prompt-shape finding (forced-choice works, open-ended doesn't) still holds — this is a second axis: which local vision model, not just which prompt shape.

## Precondition

A harness readable/compare run reports INCONCLUSIVE because the noise control failed. Re-run with --model minicpm-v (or llava:7b) before concluding the sprite itself is unreadable or the harness is broken.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
