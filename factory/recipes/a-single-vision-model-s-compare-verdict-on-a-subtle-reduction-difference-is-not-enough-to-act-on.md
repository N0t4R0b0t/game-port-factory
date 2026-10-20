# A single vision model's compare verdict on a subtle reduction difference is not enough to act on

- **axis:** `color` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-22

## Decision

Ran harness compare on two real reductions of the same critter (Lanczos-letterbox vs cropped-NEAREST). minicpm-v called it a clean win for one side, both option orders agreeing; qwen2.5vl:7b and llava:7b both reported INCONCLUSIVE (position bias) on the identical images. The difference between the two reductions was real but apparently subtle enough that most models couldn't resolve it from noise.

## Precondition

Before treating a compare verdict as a real art-direction signal (not just readable's individual VERIFIED/FAILED), get at least two models to agree. One model's clean-looking win on a subtle difference is not yet evidence; a bigger, more deliberate change (recolour, silhouette exaggeration, limb thickening) is more likely to produce a verdict all models agree on.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
