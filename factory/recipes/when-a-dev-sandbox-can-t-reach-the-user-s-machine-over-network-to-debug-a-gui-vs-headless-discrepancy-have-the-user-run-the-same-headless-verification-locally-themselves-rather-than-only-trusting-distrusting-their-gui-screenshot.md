# When a dev sandbox can't reach the user's machine over network to debug a GUI-vs-headless discrepancy, have the user run the SAME headless verification locally themselves rather than only trusting/distrusting their GUI screenshot

- **axis:** `cpu` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-29

## Decision

Spent significant back-and-forth guessing at display-environment fixes (GDK_BACKEND, SDL_VIDEODRIVER, monochrome rendering, window resize) for a garbled XRoar display on the user's real machine, none of which resolved it. The user reasonably pushed back that it could be a real code bug rather than environment. Settled it decisively and quickly by having the user run the exact same headless GDB-based verification (xroar -ui null -gdb + gdbmem.py + pmode4_to_png.py) on their OWN machine -- their local memory dump decoded correctly, proving execution/memory was correct on their exact hardware/OS/driver stack too, isolating the bug conclusively to XRoar's rendering pipeline (identified as likely NVIDIA+Wayland+KDE related) rather than continuing to guess at environment fixes or doubt the code.

## Precondition

a user reports a GUI/visual result that contradicts a sandbox's own headless verification, and the sandbox cannot reach the user's machine over the network to inspect it directly -- have the user run the identical headless verification tooling locally (not just describe what they see) before spending more time either guessing at environment fixes or re-doubting the code; a local headless result from the user's own machine is much stronger evidence than either a screenshot or a sandbox-only test

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
