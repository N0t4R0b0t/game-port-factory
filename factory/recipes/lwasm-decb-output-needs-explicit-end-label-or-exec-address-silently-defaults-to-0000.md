# lwasm DECB output needs explicit 'end <label>' or exec address silently defaults to $0000

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-28

## Decision

lwasm assembles and links a standalone .asm with no error/warning even with no 'end' directive, but writes exec address $0000 into the DECB postamble instead of the actual entry point. xroar -run then autoruns into ROM/reset territory instead of the program -- looks exactly like nothing happened (screen flashes and drops back to OK) rather than an obvious crash, so it reads as an emulator or ROM problem rather than a missing assembler directive. Confirmed by inspecting the raw hex postamble before/after adding 'end start'.

## Precondition

any standalone 6809 .asm assembled with lwasm --decb (or other lwasm DECB-format output) for autorun on a real or emulated CoCo/Dragon

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
