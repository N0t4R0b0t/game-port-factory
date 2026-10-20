# PETSCII byte value must be verified against real CHROUT output, never assumed from ASCII

- **axis:** `color` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-08-22

## Decision

Widening the C64 text charset (T0029), planned to include ASCII ^ (0x5E) and @ (0x40) since they're common ASCII/PETSCII-identical bytes in the 0x20-0x5D range. Built a real ASM probe and screenshotted actual VICE CHROUT output: 0x5E renders as an up-arrow graphic and 0x40 as an unrelated symbol, neither the intended glyph. Most of the 0x20-0x5D range IS identical between ASCII and PETSCII (confirmed empirically for ", %, [, ], <, >, +, &, $) but not all of it -- and guessing from a table remembered rather than checked would have shipped visibly wrong text.

## Precondition

Before mapping any new byte value into a C64 text-rendering pipeline that goes through CHROUT (not a custom charset), verify it against a real VICE screenshot -- a small throwaway ASM probe that CHROUTs the candidate bytes and captures the frame, as tools/harness already supports via 'harness run'. Never trust a remembered or looked-up PETSCII table without checking this specific emulator/charset combination.

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
