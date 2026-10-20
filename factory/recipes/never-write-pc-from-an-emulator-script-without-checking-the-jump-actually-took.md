# Never write PC from an emulator script without checking the jump actually took

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-14

## Decision

MAME's 6809 core suspends mid-instruction at frame boundaries (PC never equalled CURPC over 300 sampled frames), so cpu.state PC=start resumes the interrupted BASIC instruction with operand bytes read from the new address. For dizzy-coco2's T0124 image that jumped into data and hit HCF; the harness then misreported a crash as a garbage title because PC swept through the address range it waited on. Check one frame later that the program's own first effect happened (here: S <= $0100 after start's lds), and on failure force a cold start ($0071=0) + soft_reset and retry at another phase. Note soft_reset re-runs the autoboot script.

## Precondition

a Lua/autoboot harness injects a binary and sets the program counter directly on an emulated CPU core that can be suspended mid-instruction (MAME cores written as resumable state machines: m6809, hd6309, konami...)

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
