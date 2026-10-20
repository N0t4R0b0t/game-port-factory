# Settle animation questions from the original's live actor record, not its pictures

- **axis:** `raster` — this decision travels to any platform sharing that axis value
- **recorded:** 2026-09-12

## Decision

Room 51's portcullis was misread twice from source reading and screenshots (a hopping block, then a trail); logging the gate's own 16-byte RAM record from the running original (found by its constant orig* fields) gave exact y/var1/delay per tick in one run and showed it opens, slams and reopens

## Precondition

the original runs in an emulator with Lua memory access and its actor table has fields that never change at runtime to search for

A later port MUST check this precondition before reusing the decision. If it does
not hold, re-derive rather than copy — an unchecked recipe is a cargo cult.

## Outcome

_Fill in after the port ships: did this hold up?_
