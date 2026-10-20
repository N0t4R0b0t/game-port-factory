# For CoCo/Dragon graphics-mode setup, set SAM (V0-V2, F0-F6) and PIA1 ($FF22) registers directly in assembly rather than relying on xroar's -type flag to auto-type BASIC PMODE/SCREEN commands

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-29

## Decision

The -type approach (typing 'PMODE4,1:SCREEN1,1:PCLS:EXEC...' into a live BASIC session via xroar's ROM-call-intercepting auto-typer) proved unreliable in this dev sandbox specifically when combined with the -gdb debug stub -- GDB connections kept timing out/refusing in ways a plain -run invocation never did, and the root cause wasn't found despite real debugging time. Setting SAM/PIA registers directly (V0-V2 for mode family, F0-F6 for the 512-byte-granularity display start address, both bit-pair set/clear addressing at -;  bits7-4=mode nibble, bit3=CSS) sidesteps the dependency entirely, worked on the first clean try, and is arguably more correct for a real shipping game (not reliant on BASIC having already run specific commands).

## Precondition

writing bare-metal 6809 assembly for a CoCo/Dragon target that needs a specific graphics mode active -- do the SAM+PIA register setup directly rather than typing BASIC commands, especially when also using xroar's -gdb stub for headless verification

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
