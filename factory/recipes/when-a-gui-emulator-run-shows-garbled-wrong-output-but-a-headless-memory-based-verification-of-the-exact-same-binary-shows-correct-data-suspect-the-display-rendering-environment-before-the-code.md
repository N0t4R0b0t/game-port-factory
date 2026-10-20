# When a GUI emulator run shows garbled/wrong output but a headless memory-based verification of the exact same binary shows correct data, suspect the display/rendering environment before the code

- **axis:** `raster` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-29

## Decision

Spent significant time debugging room36.bin's blit routine and screen-setup code after the user's real XRoar window showed a garbled striped pattern, while headless GDB-based framebuffer verification of the identical binary showed a pixel-perfect match. Systematically ruled out interrupts, execution speed (-no-ratelimit), and artifact-color rendering (-vo-monochrome) as explanations -- none changed the symptom. The decisive test was running PLAIN STOCK BASIC's own PMODE/SCREEN commands (zero custom code) on the user's machine, which ALSO failed to visibly switch video modes -- proving the issue was in the user's specific XRoar/window-manager/display environment, not any code in this repo. A GUI verification failure is not automatically evidence the code is wrong when a headless, memory-level check already confirmed correctness -- check whether the SAME failure reproduces with zero custom code (e.g. via stock BASIC/ROM commands) before continuing to debug the code.

## Precondition

an emulator's headless/memory-level verification passes but a real GUI run shows wrong/garbled output for the same binary -- try reproducing the symptom with a minimal or zero-custom-code test (stock ROM/BASIC commands, an unrelated known-good binary) before assuming the port's own code is at fault; if the minimal test also fails, the problem is environmental (display driver, window manager, compositor), not the port

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
