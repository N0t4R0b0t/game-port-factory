# Verify a display-affecting change from rendered video, never from framebuffer memory

- **axis:** `raster` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-31

## Decision

Framebuffer bytes are written by the CPU and read back identically whether or not the video hardware can still display them. Testing an overclock by dumping framebuffer memory would have 'passed' even if the VDG had failed. Capturing the emulator's actual rendered output (MAME -video soft -snapshot_directory) is the check that can distinguish the two.

## Precondition

The change under test could plausibly affect the display path itself -- clock rate, SAM/VDG mode registers, memory timing -- rather than only what the CPU writes.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
